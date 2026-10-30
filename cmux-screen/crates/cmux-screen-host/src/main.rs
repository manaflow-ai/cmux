//! cmux-screen-host: streams this computer's screen to the cmux VNC app.
//!
//!   cmux-screen-host [--name NAME] [--signal URL] [--new-pairing] [--backend native|desktop]
//!
//! The pairing (room and secret) is kept in ~/.config/cmux-vnc-host/pairing.json,
//! the same file the Swift host uses, so a phone paired with either keeps working.

use std::path::PathBuf;

use cmux_screen_host::backend::BackendKind;
use cmux_screen_host::{Host, log};
use cmux_screen_proto::{DEFAULT_SIGNAL, Pairing};

struct Options {
    name: String,
    signal: String,
    new_pairing: bool,
    backend: BackendKind,
}

fn options() -> Options {
    let mut options = Options {
        name: hostname(),
        signal: DEFAULT_SIGNAL.into(),
        new_pairing: false,
        backend: BackendKind::Native,
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
            _ => {
                eprintln!("usage: cmux-screen-host [--name NAME] [--signal URL] [--new-pairing] [--backend native|desktop]");
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

fn pairing_file() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".config/cmux-vnc-host/pairing.json")
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
    let pairing = load_pairing(&options)?;
    log(format!("cmux screen host (Rust): {} ({:?} backend)", pairing.name, options.backend));
    println!("Pair the cmux VNC app by opening this link on the iPhone:\n\n{}\n", pairing.link());
    Host::new(pairing, options.backend).run().await;
    Ok(())
}
