//! cmux-tailnet: bring this machine's cmux node onto the tailnet and check access.
//!
//!   cmux-tailnet up     --state DIR [--hostname NAME] [--auth-key-file FILE|-]
//!   cmux-tailnet serve  --state DIR [--hostname NAME] [--port N] [--allow-tailnet-members] [--allow PRINCIPAL]...
//!   cmux-tailnet dial   --state DIR [--hostname NAME] HOST:PORT
//!
//! `up` prints the sign-in link when the node needs one and the MagicDNS name
//! once it runs. `serve` answers each connection with the access decision
//! for that peer (a WhoIs check), then echoes. `dial` connects and prints
//! what the server answered. Two machines running `serve` and `dial` prove
//! sign-in, MagicDNS, WhoIs and the owner-only default end to end.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;

use cmux_tailnet::{Access, BackendState, Node, NodeConfig};

struct Options {
    command: String,
    state: Option<PathBuf>,
    hostname: String,
    auth_key_file: Option<String>,
    port: u16,
    access: Access,
    target: Option<String>,
}

fn usage() -> ! {
    eprintln!(
        "usage: cmux-tailnet up|serve|dial --state DIR [--hostname NAME] [--auth-key-file FILE|-] [--port N] [--allow-tailnet-members] [--allow PRINCIPAL] [HOST:PORT]"
    );
    std::process::exit(2)
}

fn options() -> Options {
    let mut arguments = std::env::args().skip(1);
    let command = arguments.next().unwrap_or_else(|| usage());
    let mut options = Options {
        command,
        state: None,
        hostname: "cmux".into(),
        auth_key_file: None,
        port: 4180,
        access: Access::default(),
        target: None,
    };
    while let Some(flag) = arguments.next() {
        match flag.as_str() {
            "--state" => options.state = arguments.next().map(PathBuf::from),
            "--hostname" => options.hostname = arguments.next().unwrap_or_else(|| usage()),
            "--auth-key-file" => options.auth_key_file = arguments.next(),
            "--port" => options.port = arguments.next().and_then(|port| port.parse().ok()).unwrap_or_else(|| usage()),
            "--allow-tailnet-members" => options.access.allow_tailnet_members = true,
            "--allow" => options.access.allow.push(arguments.next().unwrap_or_else(|| usage())),
            "--deny" => options.access.deny.push(arguments.next().unwrap_or_else(|| usage())),
            _ if !flag.starts_with('-') => options.target = Some(flag),
            _ => usage(),
        }
    }
    options
}

fn auth_key(file: &Option<String>) -> std::io::Result<Option<String>> {
    match file.as_deref() {
        None => Ok(None),
        Some("-") => {
            let mut key = String::new();
            std::io::stdin().read_line(&mut key)?;
            Ok(Some(key.trim().to_owned()))
        }
        Some(path) => Ok(Some(std::fs::read_to_string(path)?.trim().to_owned())),
    }
}

/// Starts the node and returns once it runs, printing the sign-in link if it needs one.
fn bring_up(options: &Options) -> Result<Node, Box<dyn std::error::Error>> {
    let state = options.state.clone().unwrap_or_else(|| usage());
    let mut config = NodeConfig::new(state, options.hostname.clone());
    config.auth_key = auth_key(&options.auth_key_file)?;
    let node = Node::new(&config)?;
    node.start()?;
    let mut shown = String::new();
    let debug = std::env::var_os("CMUX_TAILNET_DEBUG").is_some();
    for notify in node.watch()? {
        if debug {
            eprintln!("ipn bus: state {:?} url {} err {:?}", notify.backend_state(), notify.browse_to_url.is_some(), notify.err_message);
        }
        if let Some(message) = notify.err_message.as_deref().filter(|message| !message.is_empty()) {
            eprintln!("tailnet: {message}");
        }
        if let Some(url) = notify.browse_to_url.as_deref().filter(|url| !url.is_empty() && *url != shown) {
            println!("Sign in to Tailscale: {url}");
            shown = url.to_owned();
        }
        if notify.backend_state() == Some(BackendState::Running) {
            break;
        }
    }
    let status = node.status()?;
    if status.state() != BackendState::Running {
        return Err(format!("node stopped in state {}", status.backend_state).into());
    }
    let owner = status.owner().map(|owner| owner.login_name.clone()).unwrap_or_else(|| "tagged device".into());
    println!("Running as {} (owner {owner}, addresses {})", status.dns_name().unwrap_or_default(), node.ips()?.join(", "));
    Ok(node)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let options = options();
    let node = bring_up(&options)?;
    match options.command.as_str() {
        "up" => Ok(()),
        "serve" => {
            let listener = node.listen_tcp(options.port)?;
            println!("Listening on tailnet port {}", options.port);
            loop {
                let (mut stream, remote) = match listener.accept() {
                    Ok(accepted) => accepted,
                    Err(error) => {
                        eprintln!("accept: {error}");
                        continue;
                    }
                };
                let decision = match node.whois(&remote) {
                    Ok(peer) => options.access.check(&node.status()?, &peer),
                    Err(error) => {
                        eprintln!("whois {remote}: {error}");
                        continue;
                    }
                };
                println!("{remote}: {decision:?}");
                if !decision.allowed() {
                    let _ = writeln!(stream, "denied");
                    continue;
                }
                let _ = writeln!(stream, "allowed {decision:?}");
                std::thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    while let Ok(n) = stream.read(&mut buf) {
                        if n == 0 || stream.write_all(&buf[..n]).is_err() {
                            break;
                        }
                    }
                });
            }
        }
        "dial" => {
            let target = options.target.clone().unwrap_or_else(|| usage());
            let stream = node.dial_tcp(&target)?;
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line)?;
            println!("{target} answered: {}", line.trim());
            Ok(())
        }
        _ => usage(),
    }
}
