//! The real node: libtailscale's tsnet in the app's own process, through `cmux-tailnet`. No
//! NetworkExtension, no VPN profile; only the streams this node dials go over the tailnet.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_tailnet::{BackendState, Node, NodeConfig, Status};
use cmux_tailnet_join::EmbeddedOptions;

use crate::connect::{PhoneNode, Stream};
use crate::route::{NodeState, PeerPath};

pub struct TsnetNode {
    node: Arc<Node>,
    state_dir: PathBuf,
}

impl TsnetNode {
    /// Starts the node in `state_dir` (one folder per tailnet, inside the app's container) and
    /// waits up to `timeout` for Running. Blocking: call it off the main thread.
    pub fn join(
        options: &EmbeddedOptions,
        state_dir: &Path,
        default_hostname: &str,
        timeout: Duration,
    ) -> Result<Self, String> {
        let mut config = NodeConfig::new(
            state_dir,
            options.hostname.clone().unwrap_or_else(|| default_hostname.to_owned()),
        );
        config.auth_key = Some(options.auth_key.expose().to_owned());
        config.control_url = options.control_url.clone();
        config.ephemeral = options.ephemeral;
        let node = Node::new(&config).map_err(|e| e.to_string())?;
        drop(config);
        node.start().map_err(|e| e.to_string())?;
        let deadline = Instant::now() + timeout;
        loop {
            let status = node.status().map_err(|e| e.to_string())?;
            match status.state() {
                BackendState::Running => break,
                BackendState::NeedsLogin | BackendState::NeedsMachineAuth if Instant::now() > deadline => {
                    return Err("the tailnet did not accept the key".to_owned());
                }
                _ if Instant::now() > deadline => {
                    return Err(format!(
                        "the node did not reach Running in {} s ({})",
                        timeout.as_secs(),
                        status.backend_state
                    ));
                }
                _ => std::thread::sleep(Duration::from_millis(100)),
            }
        }
        Ok(Self { node: Arc::new(node), state_dir: state_dir.to_owned() })
    }

    /// A tailnet listener on `port` (the probe's echo peer; the phone itself only dials).
    pub fn listener(&self, port: u16) -> Result<cmux_tailnet::Listener, String> {
        self.node.listen_tcp(port).map_err(|e| e.to_string())
    }

    pub fn status(&self) -> Result<Status, String> {
        self.node.status().map_err(|e| e.to_string())
    }

    /// Forget: sign out (an ephemeral node is removed by the control server), stop, and delete
    /// the node's state folder. The caller deletes the Keychain item in the same action
    /// (`key::PhoneTailnet::forget`).
    pub fn leave(self) -> Result<(), String> {
        let logout = self.node.logout().map_err(|e| e.to_string());
        let _ = self.node.close();
        std::fs::remove_dir_all(&self.state_dir)
            .or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })
            .map_err(|e| format!("remove node state: {e}"))?;
        logout
    }
}

/// The routing view of a status reply: the peer named `host` (MagicDNS name, its first label, the
/// host name, or a tailnet address).
pub fn peer_in(status: &Status, host: &str) -> Option<PeerPath> {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    let peers = status.peer.as_ref()?;
    let peer = peers.values().find(|p| {
        let dns = p.dns_name.trim_end_matches('.').to_ascii_lowercase();
        dns == host
            || dns.split('.').next() == Some(host.as_str())
            || p.host_name.eq_ignore_ascii_case(&host)
            || p.tailscale_ips.as_ref().is_some_and(|ips| ips.contains(&host))
    })?;
    let addr = peer.tailscale_ips.as_ref()?.iter().find(|ip| !ip.contains(':'))?.clone();
    Some(PeerPath { addr, online: peer.online, direct: peer.is_direct() })
}

pub fn node_state(status: &Status) -> NodeState {
    match status.state() {
        BackendState::Running => NodeState::Running,
        BackendState::NeedsLogin | BackendState::NeedsMachineAuth => NodeState::NeedsLogin,
        BackendState::Starting | BackendState::NoState => NodeState::Starting,
        _ => NodeState::Stopped,
    }
}

impl PhoneNode for TsnetNode {
    fn state(&self) -> NodeState {
        self.node.status().map_or(NodeState::Stopped, |s| node_state(&s))
    }

    fn peer(&self, host: &str) -> Option<PeerPath> {
        peer_in(&self.node.status().ok()?, host)
    }

    async fn dial(&self, addr: &str, port: u16) -> Result<Stream, String> {
        let node = Arc::clone(&self.node);
        let target = format!("{addr}:{port}");
        let std_stream = tokio::task::spawn_blocking(move || node.dial_tcp(&target))
            .await
            .map_err(|e| e.to_string())?
            .map_err(|e| e.to_string())?;
        std_stream.set_nonblocking(true).map_err(|e| e.to_string())?;
        let stream = tokio::net::UnixStream::from_std(std_stream).map_err(|e| e.to_string())?;
        Ok(Box::new(stream))
    }
}
