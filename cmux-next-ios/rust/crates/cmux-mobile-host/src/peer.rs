//! Machines as link peers (docs/multi-machine-sessions.md, "Pairing").
//!
//! A phone and a machine pair the same way (`auth`, `pairing.rs`). What they
//! may do differs: a phone keeps today's lanes; a machine gets only the grants
//! the person gave it on this Mac. Grants are set by the app on this Mac (the
//! `devices` line), never by the peer, the hub or the registry.

use serde::{Deserialize, Serialize};

/// What kind of device proved its key.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PeerKind {
    /// A paired iPhone: today's lanes, unchanged.
    #[default]
    Phone,
    /// Another of the person's Macs.
    Mac,
    /// One of the person's Linux machines running hostd.
    Linux,
}

impl PeerKind {
    /// The `kind` of an `auth` request; absent is a phone (every phone app so far).
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "" | "phone" => Some(Self::Phone),
            "mac" => Some(Self::Mac),
            "linux" => Some(Self::Linux),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Phone => "phone",
            Self::Mac => "mac",
            Self::Linux => "linux",
        }
    }

    pub fn is_machine(self) -> bool {
        self != Self::Phone
    }
}

/// One thing a machine peer may do here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Grant {
    /// See this machine, its workspaces and chats; read files in chat roots.
    View,
    /// Type into terminals, answer agents, open and close tabs (the phone's lanes).
    Control,
    /// Start agents and workspaces in listed folders (typed request, no commands).
    Run,
    /// Install a cmux build it sends, after this Mac verifies its signature.
    Install,
    /// Move a workspace in or out.
    Move,
}

impl Grant {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::View => "view",
            Self::Control => "control",
            Self::Run => "run",
            Self::Install => "install",
            Self::Move => "move",
        }
    }
}

/// The grant a machine peer needs to open `service`. `None`: the service is
/// not offered to machines at all (refused `not_granted` whatever it holds).
///
/// Phones never come here: their lanes are `policy.rs` and the service list
/// in `services.rs`, unchanged.
pub fn grant_for(service: &str) -> Option<Grant> {
    Some(match service {
        "echo" | "version" | "machine" => Grant::View,
        "file" | "file-preview" | "needs-you" => Grant::View,
        "daemon" | "acpmux" | "chief" | "upload" | "browser" | "surface" | "localhost" => Grant::Control,
        // Cloud chats ride the Mac's own Cloud session: a phone's lane only.
        _ => return None,
    })
}

/// Whether `grants` lets a machine open `service`.
pub fn allows(grants: &[Grant], service: &str) -> Result<(), &'static str> {
    match grant_for(service) {
        Some(needed) if grants.contains(&needed) => Ok(()),
        Some(_) => Err("not_granted"),
        None => Err("not_offered"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_parse_and_default_to_phone() {
        assert_eq!(PeerKind::parse(""), Some(PeerKind::Phone));
        assert_eq!(PeerKind::parse("mac"), Some(PeerKind::Mac));
        assert_eq!(PeerKind::parse("linux"), Some(PeerKind::Linux));
        assert_eq!(PeerKind::parse("Mac"), None);
        assert_eq!(PeerKind::parse("server"), None);
        assert_eq!(PeerKind::default(), PeerKind::Phone);
    }

    #[test]
    fn a_machine_opens_only_what_it_was_granted() {
        let view = [Grant::View];
        assert!(allows(&view, "machine").is_ok());
        assert!(allows(&view, "version").is_ok());
        assert_eq!(allows(&view, "daemon"), Err("not_granted"));
        assert_eq!(allows(&view, "acpmux"), Err("not_granted"));
        let control = [Grant::View, Grant::Control];
        assert!(allows(&control, "daemon").is_ok());
        assert!(allows(&control, "surface").is_ok());
        // Nothing at all: even `machine` is refused.
        assert_eq!(allows(&[], "machine"), Err("not_granted"));
        // Phone-only lanes and unknown names are never offered to machines.
        assert_eq!(allows(&[Grant::View, Grant::Control], "cloud-acpmux"), Err("not_offered"));
        assert_eq!(allows(&[Grant::View, Grant::Control], "cloud-directory"), Err("not_offered"));
        assert_eq!(allows(&[Grant::View, Grant::Control], "auth2"), Err("not_offered"));
    }

    #[test]
    fn grants_read_from_the_apps_devices_line() {
        let grants: Vec<Grant> = serde_json::from_str(r#"["view","control","install"]"#).unwrap();
        assert_eq!(grants, vec![Grant::View, Grant::Control, Grant::Install]);
        assert!(serde_json::from_str::<Vec<Grant>>(r#"["shell"]"#).is_err());
    }
}
