//! The `machine` service: what another of the person's machines may learn
//! about this one (docs/multi-machine-sessions.md, `machine.describe`).
//!
//! It answers one JSON object and closes: name, OS, arch, hostd version,
//! whether a person is logged in at this Mac's desktop, and the grants the
//! asking machine holds here. Never paths, workspaces, sessions or windows.

use bytes::Bytes;
use cmux_mobile_link::link::ChannelSender;
use serde_json::{Value, json};

use crate::peer::Grant;
use crate::services::Refusal;

/// What `describe` says; split from the I/O so tests can check every field.
pub fn describe(name: &str, grants: &[Grant], desktop: Desktop) -> Value {
    json!({
        "name": name,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "hostd": env!("CARGO_PKG_VERSION"),
        "desktop": desktop.as_str(),
        "grants": grants.iter().map(|g| g.as_str()).collect::<Vec<_>>(),
        // What a person must do at this Mac for what the peer may ask
        // ("Steps that need a person"): said, never attempted remotely.
        "needs_person": needs_person(desktop),
    })
}

/// Whether someone is at this Mac's desktop, as an app launch needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Desktop {
    /// This user owns the console: apps can open.
    Here,
    /// Another user, or nobody, is logged in at the screen.
    NotHere,
    /// Not a Mac, or unreadable.
    Unknown,
}

impl Desktop {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Here => "logged_in",
            Self::NotHere => "not_logged_in",
            Self::Unknown => "unknown",
        }
    }

    /// From the owner of `/dev/console` (macOS gives it to the user at the
    /// login window's desktop, root at the login window itself).
    pub fn current() -> Self {
        #[cfg(target_os = "macos")]
        {
            use std::os::unix::fs::MetadataExt;
            let Ok(meta) = std::fs::metadata("/dev/console") else { return Self::Unknown };
            // SAFETY: getuid has no preconditions and cannot fail.
            let me = unsafe { libc::getuid() };
            if meta.uid() == me { Self::Here } else { Self::NotHere }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self::Unknown
        }
    }
}

fn needs_person(desktop: Desktop) -> Vec<&'static str> {
    let mut out = Vec::new();
    if desktop == Desktop::NotHere {
        out.push("login");
    }
    out
}

pub async fn serve(sender: &ChannelSender, name: &str, grants: &[Grant]) -> Result<(), Refusal> {
    let reply = describe(name, grants, Desktop::current());
    let _ = sender.send(Bytes::from(reply.to_string())).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_says_only_what_a_peer_may_know() {
        let value = describe("Studio", &[Grant::View, Grant::Install], Desktop::NotHere);
        let object = value.as_object().unwrap();
        let mut keys: Vec<_> = object.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["arch", "desktop", "grants", "hostd", "name", "needs_person", "os"]);
        assert_eq!(value["grants"], json!(["view", "install"]));
        assert_eq!(value["desktop"], "not_logged_in");
        assert_eq!(value["needs_person"], json!(["login"]));
        assert_eq!(describe("Studio", &[], Desktop::Here)["needs_person"], json!([]));
    }
}
