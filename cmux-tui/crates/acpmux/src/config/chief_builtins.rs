//! The Chief's built-in presets (P0 after cx-1l61, chief decision on
//! manaflow-ai/cmux#13742). A Chief host started outside the cmux app (the
//! always-on brain's LaunchAgent, `cmux chief -p`) is not the person, so it
//! may not set a preset's spawn env. It names a built-in preset instead and
//! sends no env; acpmux fills the env from this definition, never from the
//! client:
//!
//! - fixed flags (literal keys and values);
//! - cache keys derived from the name (`optchat-<home id>-<role>`);
//! - codex paths derived from this daemon's own Chief home
//!   (`ACPMUX_CHIEF_MUX_HOME` in its own environment) and bundle, the same
//!   paths optchat-chief's `Paths` uses (`$MUX_HOME/optchat/...`);
//! - a subagent's cmux sockets from this daemon's own environment (what
//!   launchd, the app or the Chief host started it with) and PATH = the
//!   daemon's bundle directory first, then its login PATH.
//!
//! Names (the home id is 8 lowercase hex, the slot 0 to 63):
//! `optchat-chief-<id>`, `optchat-chief-codex-<id>` (turns),
//! `optchat-compact-<id>-slot-<k>` (compactor slots), `optchat-sub-<id>`,
//! `optchat-sub-<id>-claude`, `optchat-sub-<id>-codex` (subagents).
//! Any env a client sends (a built-in name included) stays the person's to
//! set (`hub/person.rs`). Always the isolated layout: optchat-chief's
//! `OPTCHAT_CHIEF_ISOLATE=0` variant is not built in.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The daemon's own environment key that names the Chief home whose codex
/// homes built-in codex presets use.
pub const CHIEF_MUX_HOME_ENV: &str = "ACPMUX_CHIEF_MUX_HOME";

/// The cmux keys a built-in subagent preset copies from this daemon's own
/// environment when present (optchat-chief `cmux_env::pinned_subset`).
pub const SUBAGENT_PINNED_KEYS: [&str; 6] = [
    "CMUX_TUI_SOCKET",
    "CMUX_MUX_SOCKET",
    // The socket path of the Chief's owner daemon: a route, not a
    // credential (any same-uid process can reach that socket); copied only
    // when this daemon itself was started with it.
    "CMUX_CHIEF_OWNER_SOCKET",
    "CMUX_BUNDLED_CLI_PATH",
    "CMUX_SOCKET_PATH",
    "CMUX_APP_DAEMON_SOCKET",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Role {
    Turn,
    Compact(u8),
    Sub,
}

/// A parsed built-in preset name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Builtin {
    role: Role,
    home_id: String,
}

fn home_id(text: &str) -> Option<String> {
    (text.len() == 8 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
        .then(|| text.to_owned())
}

/// The built-in preset `name` names, if any.
pub fn parse(name: &str) -> Option<Builtin> {
    if let Some(rest) = name.strip_prefix("optchat-chief-codex-") {
        return home_id(rest).map(|home_id| Builtin { role: Role::Turn, home_id });
    }
    if let Some(rest) = name.strip_prefix("optchat-chief-") {
        return home_id(rest).map(|home_id| Builtin { role: Role::Turn, home_id });
    }
    if let Some(rest) = name.strip_prefix("optchat-compact-") {
        let (id, slot) = rest.split_once("-slot-")?;
        let slot = (1..=2).contains(&slot.len()).then_some(slot)?;
        let k: u8 = slot.bytes().all(|b| b.is_ascii_digit()).then(|| slot.parse().ok())??;
        if k > 63 || (slot.len() == 2 && slot.starts_with('0')) {
            return None;
        }
        return home_id(id).map(|home_id| Builtin { role: Role::Compact(k), home_id });
    }
    if let Some(rest) = name.strip_prefix("optchat-sub-") {
        let id =
            rest.strip_suffix("-claude").or_else(|| rest.strip_suffix("-codex")).unwrap_or(rest);
        return home_id(id).map(|home_id| Builtin { role: Role::Sub, home_id });
    }
    None
}

/// What the definition reads from this daemon (never from a client).
pub struct Context {
    /// `ACPMUX_CHIEF_MUX_HOME` of this daemon's own environment.
    pub chief_home: Option<PathBuf>,
    /// The directory this daemon's binary is in (the app's or the brain's bin).
    pub bundle: Option<PathBuf>,
    /// The PATH this daemon's children get (its login PATH once imported).
    pub path: String,
    /// `SUBAGENT_PINNED_KEYS` present in this daemon's own environment.
    pub pinned: BTreeMap<String, String>,
}

impl Context {
    /// This daemon's own context.
    pub fn current() -> Self {
        let own = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        Self {
            chief_home: own(CHIEF_MUX_HOME_ENV).map(PathBuf::from).filter(|p| p.is_absolute()),
            bundle: std::env::current_exe()
                .ok()
                .and_then(|exe| exe.parent().map(Path::to_path_buf)),
            path: crate::login_env::path()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|| "/usr/bin:/bin".into()),
            pinned: SUBAGENT_PINNED_KEYS
                .iter()
                .filter_map(|key| own(key).map(|v| ((*key).to_owned(), v)))
                .collect(),
        }
    }

    /// optchat-chief `Paths::root`: `<Chief home>/optchat`.
    fn optchat(&self) -> Result<PathBuf, String> {
        self.chief_home.as_ref().map(|home| home.join("optchat")).ok_or_else(|| {
            format!("a built-in codex preset needs {CHIEF_MUX_HOME_ENV} in this daemon's own environment")
        })
    }

    /// optchat-chief `chief_codex_in`: the Chief's own codex binary, else
    /// the one bundled next to this daemon. Never a PATH lookup.
    fn codex(&self) -> Option<String> {
        let own = self.chief_home.as_ref().map(|h| h.join("optchat/codex/bin/codex"));
        let bundled = self.bundle.as_ref().map(|b| b.join("chief-codex/codex"));
        own.into_iter().chain(bundled).find(|p| p.is_file()).map(|p| p.display().to_string())
    }

    /// `path` with the bundle directory first, once.
    fn subagent_path(&self) -> String {
        let Some(first) = self.bundle.as_ref().map(|b| b.display().to_string()) else {
            return self.path.clone();
        };
        std::iter::once(first.clone())
            .chain(self.path.split(':').filter(|d| !d.is_empty() && *d != first).map(str::to_owned))
            .collect::<Vec<_>>()
            .join(":")
    }
}

fn flags(env: &mut BTreeMap<String, String>, keys: &[&str], value: &str) {
    for key in keys {
        env.insert((*key).to_owned(), value.to_owned());
    }
}

/// The env of built-in `b` for a harness of `family` (`codex`, `claude`, ...).
pub fn env(b: &Builtin, family: &str, ctx: &Context) -> Result<BTreeMap<String, String>, String> {
    let codex = family == "codex";
    let key = |role: &str| format!("optchat-{}-{role}", b.home_id);
    let mut env = BTreeMap::new();
    match b.role {
        Role::Turn => {
            flags(&mut env, &["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1");
            if codex {
                env.insert("CODEX_PROMPT_CACHE_KEY".into(), key("turn"));
                env.insert(
                    "CODEX_HOME".into(),
                    ctx.optchat()?.join("turn-codex").display().to_string(),
                );
                if let Some(path) = ctx.codex() {
                    env.insert("CODEX_PATH".into(), path);
                }
            } else {
                flags(&mut env, &["DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1");
                env.insert("SUBROUTER_SESSION_KEY".into(), key("turn"));
            }
        }
        Role::Compact(k) => {
            env.insert("ACPMUX_AGENT_TOOLS".into(), "0".into());
            if codex {
                let base = ctx.optchat()?.join("compactor-codex");
                env.insert("HOME".into(), base.join("home").display().to_string());
                env.insert(
                    "CODEX_HOME".into(),
                    base.join(format!("slot-{k}")).display().to_string(),
                );
                env.insert("CODEX_PROMPT_CACHE_KEY".into(), key("compact"));
                if let Some(path) = ctx.codex() {
                    env.insert("CODEX_PATH".into(), path);
                }
            } else {
                flags(
                    &mut env,
                    &[
                        "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
                        "CLAUDE_CODE_DISABLE_CLAUDE_MDS",
                        "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS",
                        "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK",
                        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                        "DISABLE_AUTOUPDATER",
                    ],
                    "1",
                );
                env.insert("SUBROUTER_SESSION_KEY".into(), key("compact"));
            }
        }
        Role::Sub => {
            flags(&mut env, &["CLAUDE_CODE_DISABLE_AUTO_MEMORY", "OPTCHAT_SUBAGENT"], "1");
            if codex {
                env.insert("CODEX_PROMPT_CACHE_KEY".into(), key("sub"));
            } else {
                env.insert("DISABLE_AUTOUPDATER".into(), "1".into());
                env.insert("SUBROUTER_SESSION_KEY".into(), key("sub"));
            }
            env.extend(ctx.pinned.clone());
            env.insert("PATH".into(), ctx.subagent_path());
        }
    }
    Ok(env)
}
