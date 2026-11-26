//! The Claude credential a Chief host on a cmux Cloud machine hands its own sessions.
//!
//! A Cloud chat on staging or production reaches a model only through the owner's credential,
//! which the Mac sends with the agent's launch (`_meta.acpmux.credentials`, acpmux
//! `agent_credentials.rs`, cmux-tui/docs/model-connections.md "Revision 2"). The machine's
//! shared coderouter route is off in staging and production (cmux-platform `wrangler.jsonc`
//! `CLOUD_CODEROUTER_EDGE_HOST`: on with #1759, off again with #1839 because fresh creates
//! carrying the rule never bound), so `coderouter.cmux.internal` does not resolve, acpmux drops
//! the route (`cloud_model_plane.rs` `machine_plane`), and a Chief turn, which no Mac launches,
//! started with no route and no login: Claude answered "Not logged in" and acpmux showed
//! "Claude is not signed in here" (`claude_auth.rs` `compose_cloud`).
//!
//! A host started with [`OPT_IN_ENV`] at `1` takes the first of [`NAMES`] from its own
//! environment once, keeps it in memory, and sends it on every `session/new` of its own Claude
//! sessions (turns and compactor nodes) on this machine, through the same field a Cloud chat's
//! launch uses. acpmux takes it only from its unix socket from a connection that runs in no
//! agent session (`agent_credentials::admit`), applies it to that agent alone, unsets the dead
//! route, and never writes it down. Without the opt-in nothing changes: a Mac host keeps its
//! user's own login and routes (`claude-sr`, `claude-sr2`, a custom base URL).

use crate::acpmux::{CHIEF_TAG, SessionSpec};
use serde_json::{Value, json};
use std::sync::OnceLock;

/// `1`: this host forwards its Claude credential to its own sessions.
pub const OPT_IN_ENV: &str = "OPTCHAT_CHIEF_TURN_CREDENTIALS";

/// The variables taken, in order: Claude Code's long-lived token (`claude setup-token`), then an
/// Anthropic API key. Both are names acpmux's `agent_credentials::NAMES` accepts.
pub const NAMES: [&str; 2] = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"];

/// The only harness a credential goes to: plain Claude Code. acpmux would apply it to any
/// `claude-…` family too and unset that harness's own route (claude-sr, claude-sr2).
pub const HARNESS: &str = "claude";

/// One credential variable. Its `Debug` never shows the value.
#[derive(Clone, PartialEq, Eq)]
pub struct Credential {
    name: &'static str,
    value: String,
}

impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Credential({} = <redacted>)", self.name)
    }
}

impl Credential {
    /// The variable's name (never its value).
    pub fn name(&self) -> &'static str {
        self.name
    }
}

/// The credential `lookup` gives, when `opt_in` is `1`: the first non-empty of [`NAMES`].
pub fn from_env(lookup: &dyn Fn(&str) -> Option<String>) -> Option<Credential> {
    if lookup(OPT_IN_ENV).as_deref() != Some("1") {
        return None;
    }
    NAMES.iter().find_map(|name| {
        let value = lookup(name)?.trim().to_owned();
        (!value.is_empty()).then_some(Credential { name, value })
    })
}

/// This process's credential, read once.
pub fn current() -> Option<&'static Credential> {
    static CURRENT: OnceLock<Option<Credential>> = OnceLock::new();
    CURRENT
        .get_or_init(|| from_env(&|k| std::env::var(k).ok()))
        .as_ref()
}

/// `session/new`'s `_meta.acpmux.credentials` for `spec`, if it gets `credential`: one of this
/// Chief's own sessions (it carries [`CHIEF_TAG`]) on this machine (no peer), on [`HARNESS`].
pub fn meta_for(spec: &SessionSpec, credential: Option<&Credential>) -> Option<Value> {
    let credential = credential?;
    let own = spec.tags.contains_key(CHIEF_TAG) && spec.peer.is_none();
    (own && spec.harness == HARNESS).then(|| json!({"env": {credential.name: credential.value}}))
}
