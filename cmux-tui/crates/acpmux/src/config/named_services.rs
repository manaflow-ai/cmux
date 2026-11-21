//! `exposedServices` and `machineForwards` in config.json: a named service this machine lets its
//! owner's other machines reach through the hub carrier, and a local listener that reaches one on
//! another machine (`named_service.rs`, `machine_forward.rs`).
//!
//! ```json
//! "exposedServices": {
//!   "lane-gh-broker": {"unix": "~/.cache/lane-gh-broker/broker.sock", "peerHeader": true},
//!   "sr2-gateway": {"tcp": "127.0.0.1:4016"}
//! },
//! "machineForwards": {
//!   "lane-gh-broker": {"from": "broker-host", "listenUnix": "~/.cache/lane-gh/broker.sock"},
//!   "sr2-gateway": {"from": "broker-host", "listenTcp": "127.0.0.1:4016"}
//! }
//! ```
//!
//! Both are empty by default: nothing is exposed and nothing is forwarded.

use serde::{Deserialize, Serialize};

/// One entry of `exposedServices`: exactly one of `unix` (a socket path under the owner's home,
/// `~/` allowed) or `tcp` (`host:port`, a loopback address unless `allowNonLoopback`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ExposedService {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tcp: Option<String>,
    /// `tcp` may name a host off loopback. The owner writes it on purpose; never a default.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub allow_non_loopback: bool,
    /// The service's first bytes on each connection are one line naming the calling machine,
    /// `acpmux-peer: <daemonId> <host>\n`, before the caller's own bytes. Off by default: a
    /// service that does not read the line never sees it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub peer_header: bool,
}

/// One entry of `machineForwards`, keyed by the service name the far machine exposes: `from`
/// (the machine: its host as the hub lists it, a peer name, or its node key) and exactly one of
/// `listenUnix` (a path, `~/` allowed) or `listenTcp` (a loopback `host:port`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MachineForward {
    pub from: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listen_unix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listen_tcp: Option<String>,
}

/// Whether `name` may name a service: 1 to 64 of `a-z 0-9 . _ -`, starting with a letter or
/// digit. The name is a key into the owner's list, never a path or an address.
pub fn valid_service_name(name: &str) -> bool {
    let mut chars = name.chars();
    (1..=64).contains(&name.len())
        && chars.next().is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-".contains(c))
}

/// `path` with a leading `~` or `~/` put under `home`.
pub fn expand_home(path: &str, home: &std::path::Path) -> std::path::PathBuf {
    match path.strip_prefix('~') {
        Some("") => home.to_path_buf(),
        Some(rest) if rest.starts_with('/') => home.join(rest.trim_start_matches('/')),
        _ => std::path::PathBuf::from(path),
    }
}

/// Where a forward listens on the dialing machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListenAt {
    /// A unix socket, made 0600; only this user's processes are served.
    Unix(std::path::PathBuf),
    /// A loopback TCP address.
    Tcp(std::net::SocketAddr),
}

impl std::fmt::Display for ListenAt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unix(path) => write!(f, "unix:{}", path.display()),
            Self::Tcp(address) => write!(f, "tcp:{address}"),
        }
    }
}

/// Whether `forward` (named `name`) is one the daemon binds, and where: a valid service name, a
/// `from`, and exactly one of an absolute unix path without `..` (`~/` under `home`) or a
/// loopback `host:port` with a port.
pub fn forward_listen(
    name: &str,
    forward: &MachineForward,
    home: Option<&std::path::Path>,
) -> Result<ListenAt, String> {
    if !valid_service_name(name) {
        return Err(format!(
            "`{name}` is not a service name (1 to 64 of a-z 0-9 . _ -, starting with a letter or digit)"
        ));
    }
    if forward.from.trim().is_empty() {
        return Err(format!("forward {name} names no machine (`from`)"));
    }
    match (forward.listen_unix.as_deref(), forward.listen_tcp.as_deref()) {
        (Some(path), None) => {
            let path = match home {
                Some(home) => expand_home(path.trim(), home),
                None => std::path::PathBuf::from(path.trim()),
            };
            if !path.is_absolute()
                || path.components().any(|c| matches!(c, std::path::Component::ParentDir))
            {
                return Err(format!(
                    "forward {name}: `{}` is not an absolute path without `..`",
                    path.display()
                ));
            }
            Ok(ListenAt::Unix(path))
        }
        (None, Some(tcp)) => {
            let address: std::net::SocketAddr = tcp
                .trim()
                .parse()
                .map_err(|_| format!("forward {name}: `{tcp}` is not an ip:port"))?;
            if !address.ip().is_loopback() || address.port() == 0 {
                return Err(format!(
                    "forward {name}: `{tcp}` must be a loopback address with a port \
                     (127.0.0.1:PORT or [::1]:PORT)"
                ));
            }
            Ok(ListenAt::Tcp(address))
        }
        _ => Err(format!("forward {name} needs exactly one of listenUnix and listenTcp")),
    }
}

/// The owner's home: `$HOME`, else the OS's answer.
pub fn owner_home() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(dirs::home_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_names_are_plain_keys() {
        for good in ["lane-gh-broker", "sr2-gateway", "a", "x.y_z-1"] {
            assert!(valid_service_name(good), "{good}");
        }
        let long = "a".repeat(65);
        for bad in ["", "-x", "../etc", "a/b", "A", "a b", "a:1", long.as_str()] {
            assert!(!valid_service_name(bad), "{bad}");
        }
    }

    #[test]
    fn the_config_shape_reads_and_drops_unknown_fields() {
        let exposed: std::collections::BTreeMap<String, ExposedService> =
            serde_json::from_value(serde_json::json!({
                "lane-gh-broker": {"unix": "~/.cache/lane-gh-broker/broker.sock", "peerHeader": true},
                "sr2-gateway": {"tcp": "127.0.0.1:4016"},
            }))
            .unwrap();
        assert!(exposed["lane-gh-broker"].peer_header);
        assert_eq!(exposed["sr2-gateway"].tcp.as_deref(), Some("127.0.0.1:4016"));
        // A command-bearing field is not a field: it is dropped on read, never run or kept.
        let read: ExposedService =
            serde_json::from_value(serde_json::json!({"unix": "/x", "argv": ["sh"]})).unwrap();
        assert_eq!(read, ExposedService { unix: Some("/x".into()), ..Default::default() });
        let forward: MachineForward = serde_json::from_value(serde_json::json!({
            "from": "broker-host", "listenUnix": "~/.cache/lane-gh/broker.sock",
        }))
        .unwrap();
        assert_eq!(forward.from, "broker-host");
    }

    #[test]
    fn a_forward_listens_on_a_private_path_or_loopback_only() {
        let home = std::path::Path::new("/home/u");
        let at = |unix: Option<&str>, tcp: Option<&str>| {
            let forward = MachineForward {
                from: "broker-host".into(),
                listen_unix: unix.map(str::to_owned),
                listen_tcp: tcp.map(str::to_owned),
            };
            forward_listen("lane-gh-broker", &forward, Some(home))
        };
        assert_eq!(
            at(Some("~/.cache/lane-gh/broker.sock"), None).unwrap(),
            ListenAt::Unix(home.join(".cache/lane-gh/broker.sock"))
        );
        assert_eq!(
            at(None, Some("127.0.0.1:4016")).unwrap(),
            ListenAt::Tcp("127.0.0.1:4016".parse().unwrap())
        );
        for bad in [
            at(None, None),
            at(Some("/x.sock"), Some("127.0.0.1:1")),
            at(Some("rel.sock"), None),
            at(Some("~/../x.sock"), None),
            at(None, Some("0.0.0.0:4016")),
            at(None, Some("10.1.2.3:4016")),
            at(None, Some("127.0.0.1:0")),
            at(None, Some("localhost:4016")),
        ] {
            assert!(bad.is_err(), "{bad:?}");
        }
        let nobody = MachineForward {
            from: " ".into(),
            listen_tcp: Some("127.0.0.1:1".into()),
            ..Default::default()
        };
        assert!(forward_listen("x", &nobody, Some(home)).is_err());
        let fine = MachineForward {
            from: "m".into(),
            listen_tcp: Some("127.0.0.1:1".into()),
            ..Default::default()
        };
        assert!(forward_listen("../x", &fine, Some(home)).is_err());
    }

    #[test]
    fn a_tilde_goes_under_home() {
        let home = std::path::Path::new("/home/u");
        assert_eq!(expand_home("~/a/b.sock", home), home.join("a/b.sock"));
        assert_eq!(expand_home("~", home), home);
        assert_eq!(expand_home("/tmp/x", home), std::path::PathBuf::from("/tmp/x"));
        assert_eq!(expand_home("~other/x", home), std::path::PathBuf::from("~other/x"));
    }
}
