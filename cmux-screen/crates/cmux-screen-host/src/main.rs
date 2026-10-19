//! cmux-screen-host: streams this computer's screen to a cmux viewer.
//!
//!   cmux-screen-host [--name NAME] [--backend native|desktop]
//!                    [--no-tailnet] [--tailnet-hostname NAME] [--tailnet-auth-key-file FILE|-]
//!                    [--tailnet-port N] [--allow-tailnet-members] [--allow PRINCIPAL]...
//!                    [--no-room] [--signal URL] [--new-pairing]
//!
//! Viewers arrive two ways:
//! - the tailnet (default): the host is its own device, `cmux-<computer>`, on
//!   the user's tailnet through embedded Tailscale (no Tailscale app needed).
//!   The first run prints a sign-in link; the login is kept in
//!   ~/.config/cmux-screen/tailnet. Only the owner's devices are served unless
//!   `--allow` or `--allow-tailnet-members` widens it.
//! - the Worker room (fallback for viewers with no tailnet). The pairing
//!   (room and secret) is kept in ~/.config/cmux-vnc-host/pairing.json, the
//!   same file the Swift host uses, so a phone paired with either keeps working.

use std::path::PathBuf;

use std::sync::Arc;

use cmux_screen_host::backend::BackendKind;
use cmux_screen_host::tailnet_signal::{DEFAULT_PORT, TailnetSignal};
use cmux_screen_host::{Host, log};
use cmux_screen_proto::{DEFAULT_SIGNAL, Pairing};
use cmux_tailnet::{Access, BackendState, Node, NodeConfig};

struct Options {
    name: String,
    signal: String,
    new_pairing: bool,
    backend: BackendKind,
    tailnet: bool,
    tailnet_hostname: Option<String>,
    tailnet_auth_key_file: Option<String>,
    tailnet_port: u16,
    access: Access,
    room: bool,
}

const USAGE: &str = "usage: cmux-screen-host [--name NAME] [--backend native|desktop] [--no-tailnet] [--tailnet-hostname NAME] [--tailnet-auth-key-file FILE|-] [--tailnet-port N] [--allow-tailnet-members] [--allow PRINCIPAL] [--no-room] [--signal URL] [--new-pairing]";

fn options() -> Options {
    let mut options = Options {
        name: hostname(),
        signal: DEFAULT_SIGNAL.into(),
        new_pairing: false,
        backend: BackendKind::Native,
        tailnet: true,
        tailnet_hostname: None,
        tailnet_auth_key_file: None,
        tailnet_port: DEFAULT_PORT,
        access: Access::default(),
        room: true,
    };
    let mut arguments = std::env::args().skip(1);
    while let Some(flag) = arguments.next() {
        match flag.as_str() {
            "--name" => options.name = arguments.next().unwrap_or(options.name),
            "--signal" => options.signal = arguments.next().unwrap_or(options.signal),
            "--new-pairing" => options.new_pairing = true,
            "--backend" => {
                options.backend = match arguments.next().as_deref() {
                    Some("desktop") => BackendKind::Desktop,
                    _ => BackendKind::Native,
                }
            }
            "--no-tailnet" => options.tailnet = false,
            "--tailnet-hostname" => options.tailnet_hostname = arguments.next(),
            "--tailnet-auth-key-file" => options.tailnet_auth_key_file = arguments.next(),
            "--tailnet-port" => {
                options.tailnet_port = arguments.next().and_then(|port| port.parse().ok()).unwrap_or(options.tailnet_port)
            }
            "--allow-tailnet-members" => options.access.allow_tailnet_members = true,
            "--allow" => options.access.allow.extend(arguments.next()),
            "--deny" => options.access.deny.extend(arguments.next()),
            "--no-room" => options.room = false,
            _ => {
                eprintln!("{USAGE}");
                std::process::exit(if flag == "--help" || flag == "-h" { 0 } else { 2 });
            }
        }
    }
    options
}

fn hostname() -> String {
    std::process::Command::new("scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "Computer".into())
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

fn pairing_file() -> PathBuf {
    home().join(".config/cmux-vnc-host/pairing.json")
}

/// `cmux-` and the computer name as a DNS label: `Lawrence's Mac mini` -> `cmux-lawrences-mac-mini`.
fn tailnet_hostname(name: &str) -> String {
    let mut label = String::from("cmux-");
    for c in name.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            label.push(c);
        } else if (c.is_whitespace() || c == '-' || c == '_' || c == '.') && !label.ends_with('-') {
            label.push('-');
        }
    }
    let label = label.trim_end_matches('-');
    label.chars().take(63).collect()
}

fn read_auth_key(file: Option<&str>) -> anyhow::Result<Option<String>> {
    Ok(match file {
        None => None,
        Some("-") => {
            let mut key = String::new();
            std::io::stdin().read_line(&mut key)?;
            Some(key.trim().to_owned())
        }
        Some(path) => Some(std::fs::read_to_string(path)?.trim().to_owned()),
    })
}

/// Starts this host's tailnet node and reports sign-in as it happens (IPN bus events, no polling).
fn start_tailnet(options: &Options) -> anyhow::Result<TailnetSignal> {
    let hostname = options.tailnet_hostname.clone().unwrap_or_else(|| tailnet_hostname(&options.name));
    let mut config = NodeConfig::new(home().join(".config/cmux-screen/tailnet"), hostname);
    config.auth_key = read_auth_key(options.tailnet_auth_key_file.as_deref())?;
    let node = Arc::new(Node::new(&config)?);
    node.start()?;
    let watcher = node.clone();
    std::thread::Builder::new().name("tailnet-state".into()).spawn(move || {
        let Ok(watch) = watcher.watch() else { return };
        let mut shown = String::new();
        for notify in watch {
            if let Some(url) = notify.browse_to_url.as_deref().filter(|url| !url.is_empty() && *url != shown) {
                println!("Sign in to Tailscale to put this computer on your tailnet:\n\n{url}\n");
                shown = url.to_owned();
            }
            match notify.backend_state() {
                Some(BackendState::Running) => {
                    let status = watcher.status().unwrap_or_default();
                    let owner = status.owner().map(|owner| owner.login_name.clone()).unwrap_or_else(|| "a tagged device".into());
                    log(format!("on the tailnet as {} (owner {owner})", status.dns_name().unwrap_or_default()));
                }
                Some(BackendState::NeedsLogin) if shown.is_empty() => log("tailnet: waiting for sign-in"),
                Some(BackendState::NeedsMachineAuth) => log("tailnet: an admin must approve this device"),
                _ => {}
            }
        }
    })?;
    Ok(TailnetSignal { node, access: options.access.clone(), port: options.tailnet_port })
}

fn load_pairing(options: &Options) -> anyhow::Result<Pairing> {
    let file = pairing_file();
    let saved = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice::<Pairing>(&data).ok());
    let mut pairing = match saved {
        Some(saved) if !options.new_pairing && saved.signal == options.signal && saved.is_stream() => saved,
        _ => Pairing::generate(&options.name, &options.signal, "stream")?,
    };
    pairing.name = options.name.clone();
    save_private(&file, &serde_json::to_vec(&pairing)?)?;
    Ok(pairing)
}

/// Writes the room secret readable only by this user from the start
/// (folder 0700, file 0600), as the Swift host does.
fn save_private(file: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    if let Some(folder) = file.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(folder)?;
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
    }
    let mut out = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(file)?;
    // An existing file keeps its old mode on open: tighten it too.
    out.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    out.write_all(data)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let options = options();
    if !options.tailnet && !options.room {
        anyhow::bail!("--no-tailnet and --no-room leave no way for a viewer to connect");
    }
    log(format!("cmux screen host (Rust): {} ({:?} backend)", options.name, options.backend));
    let tailnet = if options.tailnet { Some(start_tailnet(&options)?) } else { None };
    let pairing = if options.room {
        let pairing = load_pairing(&options)?;
        println!("Fallback for viewers without a tailnet: open this pairing link on the iPhone:\n\n{}\n", pairing.link());
        Some(pairing)
    } else {
        None
    };
    Host::new(options.name.clone(), pairing, tailnet, options.backend).run().await;
    Ok(())
}
