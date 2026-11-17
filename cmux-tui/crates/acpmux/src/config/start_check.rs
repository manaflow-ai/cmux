//! What a daemon refuses to start with in config.json, in one place. The daemon's start runs it
//! (`daemon.rs`), and so does everything that writes or applies config.json for it:
//! `acpmux config --set` ([`Config::set`] refuses a value that fails it and leaves the file as
//! it was), `_acpmux/reload_config` (`hub/catalog_reload.rs` keeps the running config), and
//! `daemon start` / `daemon status` (`daemon::saved_start_refusal`, before a daemon is spawned).
//! A config the CLI writes is always one the daemon starts with (2026-11-15: `config --set
//! transport.wireguard=true` without `wireguardStatic` left the daemon down on two machines).
//!
//! A start-time check of config.json goes here, not only into the start: that is the class of
//! bug this module closes. `config_set_never_writes_a_config_the_daemon_refuses` and
//! `config_set_refuses_what_any_start_check_refuses` (`config/tests.rs`) pin it.

use super::*;

impl Config {
    /// Why a daemon started from this config would refuse to start, or Ok: every check below.
    /// The listener check may resolve a host name (blocking), as the start does.
    pub fn start_refusal(&self) -> Result<()> {
        self.settings_refusal()?;
        self.listen_refusal()
    }

    /// The checks of [`Self::start_refusal`] that need no address lookup: the WireGuard
    /// transport's settings (`wireguard::enabled_settings`). The daemon's start runs these right
    /// after it loads config.json; it checks its listener where it binds it (it may come from
    /// `--listen`).
    pub(crate) fn settings_refusal(&self) -> Result<()> {
        crate::wireguard::enabled_settings(self).map(drop)
    }

    /// `websocket.listen` on a network address without `websocket.allowInsecureNetwork`: the
    /// address a start would listen on (`daemon::first_run_listen`; only the shared home keeps the
    /// fixed port), checked as the start checks it (`server::check_listen_address`).
    fn listen_refusal(&self) -> Result<()> {
        let Some(websocket) = &self.websocket else { return Ok(()) };
        let shared = match self.path.as_deref().and_then(Path::parent) {
            Some(home) => crate::daemon::is_shared_home(home),
            None => crate::daemon::uses_shared_home(),
        };
        let listen = crate::daemon_parts::first_run_listen(shared, Some(&websocket.listen));
        crate::ws_auth::check_listen_address_blocking(listen, websocket.allow_insecure_network)
            .with_context(|| format!("refusing websocket.listen {listen}"))
    }
}
