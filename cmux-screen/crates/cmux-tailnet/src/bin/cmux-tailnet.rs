//! cmux-tailnet: bring this machine's cmux node onto the tailnet and check access.
//!
//!   cmux-tailnet up     --state DIR [--hostname NAME] [--auth-key-file FILE|-]
//!   cmux-tailnet serve  --state DIR [--hostname NAME] [--port N] [--allow-tailnet-members] [--allow PRINCIPAL]...
//!   cmux-tailnet dial   --state DIR [--hostname NAME] HOST:PORT
//!   cmux-tailnet forward --state DIR [--hostname NAME] --local 127.0.0.1:PORT HOST:PORT
//!   cmux-tailnet turn-serve --state DIR [--hostname NAME] [--port N] [--allow ...]   (feature relay)
//!   cmux-tailnet turn-check --via 127.0.0.1:PORT --user U --pass P --peer IP:PORT   (feature relay)
//!
//! `up` prints the sign-in link when the node needs one and the MagicDNS name
//! once it runs. `serve` answers each connection with the access decision
//! for that peer (a WhoIs check), then echoes. `dial` connects and prints
//! what the server answered. Two machines running `serve` and `dial` prove
//! sign-in, MagicDNS, WhoIs and the owner-only default end to end.
//!
//! `forward` accepts TCP on a loopback address and carries each connection
//! over this node to HOST:PORT on the tailnet, so a program with no tailnet
//! interface (a viewer's libwebrtc) reaches the host's signaling (4180) or
//! TURN relay (4181). `turn-serve` runs the relay (default port 4181) with a
//! UDP echo as its only allowed peer and prints one credential;
//! `turn-check` allocates through the relay and waits for the echo
//! (`cmux-screen/scripts/tailnet-turn-check.sh` runs both sides).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Arc;

use cmux_tailnet::{Access, BackendState, Node, NodeConfig};

struct Options {
    command: String,
    state: Option<PathBuf>,
    hostname: String,
    auth_key_file: Option<String>,
    port: Option<u16>,
    access: Access,
    target: Option<String>,
    local: Option<String>,
    via: Option<String>,
    user: Option<String>,
    pass: Option<String>,
    peer: Option<String>,
}

fn usage() -> ! {
    eprintln!(
        "usage: cmux-tailnet up|serve|dial|forward|turn-serve --state DIR [--hostname NAME] [--auth-key-file FILE|-] [--port N] [--allow-tailnet-members] [--allow PRINCIPAL] [--local 127.0.0.1:PORT] [HOST:PORT]\n       cmux-tailnet turn-check --via HOST:PORT --user U --pass P --peer IP:PORT"
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
        port: None,
        access: Access::default(),
        target: None,
        local: None,
        via: None,
        user: None,
        pass: None,
        peer: None,
    };
    while let Some(flag) = arguments.next() {
        match flag.as_str() {
            "--state" => options.state = arguments.next().map(PathBuf::from),
            "--hostname" => options.hostname = arguments.next().unwrap_or_else(|| usage()),
            "--auth-key-file" => options.auth_key_file = arguments.next(),
            "--port" => options.port = Some(arguments.next().and_then(|port| port.parse().ok()).unwrap_or_else(|| usage())),
            "--local" => options.local = arguments.next(),
            "--via" => options.via = arguments.next(),
            "--user" => options.user = arguments.next(),
            "--pass" => options.pass = arguments.next(),
            "--peer" => options.peer = arguments.next(),
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

/// Carries one loopback connection over the tailnet, both directions, until either side ends.
fn splice(client: TcpStream, remote: std::os::unix::net::UnixStream) -> std::io::Result<()> {
    client.set_nodelay(true)?;
    let (mut client_in, mut remote_out) = (client.try_clone()?, remote.try_clone()?);
    let upstream = std::thread::spawn(move || {
        let _ = std::io::copy(&mut client_in, &mut remote_out);
        let _ = remote_out.shutdown(std::net::Shutdown::Write);
    });
    let (mut remote_in, mut client_out) = (remote, client);
    let _ = std::io::copy(&mut remote_in, &mut client_out);
    let _ = client_out.shutdown(std::net::Shutdown::Write);
    let _ = upstream.join();
    Ok(())
}

fn forward(node: Node, options: &Options) -> Result<(), Box<dyn std::error::Error>> {
    let local: SocketAddr = options.local.as_deref().unwrap_or_else(|| usage()).parse()?;
    // A forward on a LAN address would hand this node's tailnet identity to the LAN.
    if !local.ip().is_loopback() {
        return Err(format!("--local {local}: only a loopback address").into());
    }
    let target = options.target.clone().unwrap_or_else(|| usage());
    let listener = TcpListener::bind(local)?;
    println!("Forwarding {} -> {target} over the tailnet", listener.local_addr()?);
    let node = Arc::new(node);
    for client in listener.incoming() {
        let Ok(client) = client else { continue };
        let (node, target) = (node.clone(), target.clone());
        std::thread::spawn(move || match node.dial_tcp(&target) {
            Ok(remote) => {
                if let Err(error) = splice(client, remote) {
                    eprintln!("forward {target}: {error}");
                }
            }
            Err(error) => eprintln!("forward {target}: {error}"),
        });
    }
    Ok(())
}

#[cfg(feature = "relay")]
fn turn_serve(node: Node, options: &Options) -> Result<(), Box<dyn std::error::Error>> {
    use cmux_tailnet::relay::{DEFAULT_RELAY_PORT, TurnRelay};
    let runtime = tokio::runtime::Runtime::new()?;
    let node = Arc::new(node);
    let port = options.port.unwrap_or(DEFAULT_RELAY_PORT);
    let log: cmux_tailnet::relay::Log = Arc::new(|line: &str| eprintln!("{line}"));
    let relay = TurnRelay::serve(node.clone(), options.access.clone(), port, runtime.handle().clone(), log)?;
    // The echo listens where the host's libwebrtc would: a LAN (or loopback) address of this machine.
    let echo = std::net::UdpSocket::bind("0.0.0.0:0")?;
    let probe = std::net::UdpSocket::bind("0.0.0.0:0")?;
    let lan = probe.connect("192.0.2.1:9").and_then(|()| probe.local_addr()).map(|addr| addr.ip()).unwrap_or([127, 0, 0, 1].into());
    let echo_addr = SocketAddr::new(lan, echo.local_addr()?.port());
    let grant = relay.grant(None)?;
    grant.allow_peer(echo_addr);
    println!("TURN relay on tailnet port {port} ({})", relay.ice_url(&node).unwrap_or_default());
    println!("On the viewer: cmux-tailnet turn-check --via <forward> --user {} --pass {} --peer {echo_addr}", grant.username(), grant.password());
    let mut buf = [0u8; 2048];
    loop {
        let (n, from) = echo.recv_from(&mut buf)?;
        println!("echo: {n} bytes from {from}");
        echo.send_to(&buf[..n], from)?;
    }
}

#[cfg(feature = "relay")]
fn turn_check(options: &Options) -> Result<(), Box<dyn std::error::Error>> {
    let via: SocketAddr = options.via.as_deref().unwrap_or_else(|| usage()).parse()?;
    let peer: SocketAddr = options.peer.as_deref().unwrap_or_else(|| usage()).parse()?;
    let (user, pass) = (options.user.as_deref().unwrap_or_else(|| usage()), options.pass.as_deref().unwrap_or_else(|| usage()));
    let runtime = tokio::runtime::Runtime::new()?;
    let probe = runtime.block_on(cmux_tailnet::relay::probe(via, user, pass, peer))?;
    println!(
        "turn-check ok: relay {} echoed {} bytes from {peer} in {} ms",
        probe.relayed,
        probe.echoed,
        probe.round_trip.as_millis()
    );
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let options = options();
    #[cfg(feature = "relay")]
    if options.command == "turn-check" {
        return turn_check(&options);
    }
    let node = bring_up(&options)?;
    match options.command.as_str() {
        "up" => Ok(()),
        "forward" => forward(node, &options),
        #[cfg(feature = "relay")]
        "turn-serve" => turn_serve(node, &options),
        "serve" => {
            let port = options.port.unwrap_or(4180);
            let listener = node.listen_tcp(port)?;
            println!("Listening on tailnet port {port}");
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
