use std::fmt;
use std::time::Duration;

use optchat_core::{CompactPrompt, VIEW};

use crate::report::{stderr_reporter, Reporter};
use crate::RETRY;

/// The team subrouter, which speaks the Anthropic Messages API and ignores the key.
pub const DEFAULT_BASE_URL: &str = "http://cmux-lawrences-mac-mini:31415";
/// Environment variable that overrides `DEFAULT_BASE_URL`.
pub const BASE_URL_ENV: &str = "OPTCHAT_ANTHROPIC_BASE_URL";
/// Environment variable with the key for a base URL that needs one.
pub const API_KEY_ENV: &str = "OPTCHAT_ANTHROPIC_API_KEY";
/// What the team subrouter gets: it ignores the key, and a real key must not
/// travel to it.
pub const SUBROUTER_KEY: &str = "subrouter";
/// The compactor model: Claude Haiku 5.5 at high effort, as the reference
/// client runs it (section 4.2 uses Sonnet at medium). About half the time
/// per node and a fraction of the cost; it writes over-long lines more
/// often, which the ruler and the "Too long" retry handle.
/// `OPTCHAT_COMPACTOR_MODEL` (or engine.json's `compactor-model`) picks
/// another, e.g. `claude-sonnet-5-5`.
pub const DEFAULT_MODEL: &str = "claude-haiku-5-5";
/// The compactor's `output_config.effort` (`OPTCHAT_COMPACTOR_EFFORT`).
pub const DEFAULT_EFFORT: &str = "high";
/// Where a node goes when the compactor model declines it. Claude Sonnet 5
/// declines in fewer safeguard categories than Sonnet 5.5 (no bio,
/// reasoning-extraction or general-harms classifiers on the same scale), so a
/// pasted exploit write-up or a log with odd content still gets its line.
pub const DEFAULT_FALLBACK_MODEL: &str = "claude-sonnet-5";

/// How one chat runs. Fixed for the life of the process: the compactor's
/// system prompt heads every cached prefix, so it must not change per call.
#[derive(Clone)]
pub struct Config {
    /// The agent's name in the compactor prompt.
    pub agent: String,
    /// Which compactor prompt (default Taelin's).
    pub prompt: CompactPrompt,
    /// Compactor model id.
    pub model: String,
    /// Model a declined node (`stop_reason: refusal`) is built with instead;
    /// None keeps retrying the same call every `retry`. A refusal repeats on
    /// every try, so without a fallback one message would block rule 3, and
    /// with it every later turn, forever.
    pub fallback_model: Option<String>,
    /// Also send the Messages API's server-side `fallbacks: "default"` (beta
    /// `server-side-fallback-2026-07-01`). Off by default: the team subrouter
    /// may not forward the beta, and a 400 there would fail every call.
    pub server_fallback: bool,
    /// `output_config.effort` (`DEFAULT_EFFORT`); low effort overshot the
    /// size limit much more (section 4.2).
    pub effort: Option<String>,
    /// Base URL of the Messages API (`/v1/messages` is appended).
    pub base_url: String,
    /// `x-api-key` (see `api_key`).
    pub api_key: String,
    /// Output cap per compactor call; thinking tokens count against it.
    pub max_tokens: u32,
    /// Wall-clock cap on one HTTP call, so a stalled connection cannot hold
    /// a compactor slot (and with rule 3 every later level-0 node) for long:
    /// it fails and is retried. A compactor reply is one line of at most
    /// 512 bytes plus medium-effort thinking, well inside it.
    pub http_timeout: Duration,
    /// The view's byte budget.
    pub budget: usize,
    /// The turns' tool list for the API compactor (spec 4: a compaction
    /// sends the turns' system prompt and tools, never called, so it reads
    /// them from the turns' cache entry). None sends no tools.
    pub tools: Option<serde_json::Value>,
    /// Wait before retrying a failed node.
    pub retry: Duration,
    pub reporter: Reporter,
    /// The memory database; None puts it in the chat directory
    /// (`memory.sqlite3`). The Chief keeps it at `$MUX_HOME/optchat/memory.sqlite3`.
    pub db: Option<std::path::PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        let base_url = std::env::var(BASE_URL_ENV)
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_BASE_URL.to_string());
        Config {
            agent: "OptChat".to_string(),
            prompt: CompactPrompt::Taelin,
            model: DEFAULT_MODEL.to_string(),
            fallback_model: Some(DEFAULT_FALLBACK_MODEL.to_string()),
            server_fallback: false,
            effort: Some(DEFAULT_EFFORT.to_string()),
            api_key: api_key(&base_url, |k| std::env::var(k).ok()),
            base_url,
            max_tokens: 16_000,
            http_timeout: Duration::from_secs(240),
            budget: VIEW,
            tools: None,
            retry: RETRY,
            reporter: stderr_reporter(),
            db: None,
        }
    }
}

/// The key for `base_url`: `OPTCHAT_ANTHROPIC_API_KEY` when set; else, for
/// any base URL but the team subrouter, `ANTHROPIC_API_KEY`; else the
/// placeholder the subrouter ignores. An always-on Mac mini off the tailnet
/// points the base URL at api.anthropic.com and needs a real key, or every
/// call is a 401 retried forever and no turn ever starts.
pub fn api_key(base_url: &str, env: impl Fn(&str) -> Option<String>) -> String {
    let set = |k: &str| env(k).filter(|v| !v.trim().is_empty());
    if let Some(key) = set(API_KEY_ENV) {
        return key;
    }
    if base_url.trim_end_matches('/') != DEFAULT_BASE_URL {
        if let Some(key) = set("ANTHROPIC_API_KEY") {
            return key;
        }
    }
    SUBROUTER_KEY.to_string()
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("agent", &self.agent)
            .field("prompt", &self.prompt.name())
            .field("model", &self.model)
            .field("fallback_model", &self.fallback_model)
            .field("server_fallback", &self.server_fallback)
            .field("effort", &self.effort)
            .field("base_url", &self.base_url)
            .field("max_tokens", &self.max_tokens)
            .field("http_timeout", &self.http_timeout)
            .field("budget", &self.budget)
            .field("retry", &self.retry)
            .field("db", &self.db)
            .finish_non_exhaustive()
    }
}
