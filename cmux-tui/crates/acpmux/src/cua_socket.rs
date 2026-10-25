//! The tag's cmux Computer Use helper socket for this daemon's agent sessions.
//!
//! The cmux app starts the Developer ID signed helper (`cmux-cua serve`) on a
//! tag-scoped socket when the user turns Computer Use on. An unsigned DEV app
//! exports [`APP_SOCKET_ENV`] and the agent token [`APP_TOKEN_ENV`] when it
//! spawns this daemon. A signed app sends them after both sides verify the
//! connected socket peer (`_acpmux/computer_use_enroll`). Each `cmux-cua mcp`
//! (agent_tools.rs) gets that
//! socket as `--socket` (the proxy reads its socket only from that flag) and
//! the token as `CMUX_CUA_SOCKET_AUTH_TOKEN`. This daemon never starts a
//! helper. Unset, `cmux-cua mcp` uses its default socket.
//!
//! The host token ([`APP_HOST_TOKEN_ENV`]) never reaches an agent: every
//! agent spawn removes it and the other helper tokens from the env it
//! inherits from this daemon ([`scrub_agent_env`]).

use std::path::PathBuf;
use std::sync::RwLock;

/// The tag's helper socket the cmux app exports to its children.
pub const APP_SOCKET_ENV: &str = "CMUX_NEXT_CUA_SOCKET";
/// The agent token for [`APP_SOCKET_ENV`].
pub const APP_TOKEN_ENV: &str = "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN";
/// The host token for [`APP_SOCKET_ENV`]: never given to an agent.
pub const APP_HOST_TOKEN_ENV: &str = "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN";
/// Helper tokens a spawned agent must not inherit from the daemon's env.
pub const AGENT_SCRUBBED_ENV: &[&str] = &[
    APP_TOKEN_ENV,
    APP_HOST_TOKEN_ENV,
    "CMUX_CUA_SOCKET_AUTH_TOKEN",
    "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN",
    crate::cua_v2::ENDPOINT_DIR_ENV,
];

/// Where this daemon's sessions reach the tag's helper.
#[derive(Clone, PartialEq, Eq)]
pub struct Socket {
    pub path: PathBuf,
    /// Empty when the app exported no agent token.
    pub token: String,
}

impl std::fmt::Debug for Socket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the token.
        f.debug_struct("Socket").field("path", &self.path).finish_non_exhaustive()
    }
}

/// `None`: no signed app has enrolled yet. `Some(None)`: it explicitly
/// cleared the endpoint. `Some(Some(_))`: the current in-memory endpoint.
static ENROLLED: RwLock<Option<Option<Socket>>> = RwLock::new(None);

fn current_with(
    slot: &RwLock<Option<Option<Socket>>>,
    fallback: impl FnOnce() -> Option<Socket>,
) -> Option<Socket> {
    match slot.read().unwrap_or_else(std::sync::PoisonError::into_inner).clone() {
        Some(value) => value,
        None => fallback(),
    }
}

/// The signed app's latest in-memory socket, or the unsigned DEV spawn env.
pub fn from_env() -> Option<Socket> {
    current_with(&ENROLLED, || {
        let var = |k: &str| std::env::var(k).ok();
        select(var(APP_SOCKET_ENV), var(APP_TOKEN_ENV))
    })
}

/// Replace the signed app's post-peer-check endpoint. Empty `socket` clears it.
pub fn enroll(socket: String, agent_token: String) {
    let value = select(Some(socket), Some(agent_token));
    *ENROLLED.write().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(value);
}

/// [`from_env`] with the values passed in. An empty socket is unset.
pub fn select(app_socket: Option<String>, app_token: Option<String>) -> Option<Socket> {
    let path = app_socket.filter(|s| !s.trim().is_empty())?;
    Some(Socket { path: PathBuf::from(path), token: app_token.unwrap_or_default() })
}

/// Remove the helper tokens from a spawned agent's inherited env.
pub fn scrub_agent_env(cmd: &mut tokio::process::Command) {
    for key in AGENT_SCRUBBED_ENV {
        cmd.env_remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn post_launch_enrollment_replaces_and_clears_the_spawn_fallback() {
        let slot = RwLock::new(None);
        let fallback = || Some(Socket { path: "/spawn.sock".into(), token: "spawn-token".into() });
        assert_eq!(current_with(&slot, fallback).unwrap().path, PathBuf::from("/spawn.sock"));

        *slot.write().unwrap() =
            Some(select(Some("/enrolled.sock".into()), Some("new-token".into())));
        let enrolled = current_with(&slot, fallback).unwrap();
        assert_eq!(enrolled.path, PathBuf::from("/enrolled.sock"));
        assert_eq!(enrolled.token, "new-token");

        *slot.write().unwrap() = Some(select(Some(String::new()), Some("ignored".into())));
        assert!(current_with(&slot, fallback).is_none());
    }
}
