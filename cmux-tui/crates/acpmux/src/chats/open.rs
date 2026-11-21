//! How a chat opens again (ALL-CHATS-ON-DEVICE S5, C1). The daemon plans;
//! the client acts, so every open goes through the client's normal path:
//!
//! - `adopt`: a Claude/Codex chat in the store of a configured profile. The
//!   plan carries ready `session/new` params (that profile, `_meta.acpmux.adopt`),
//!   so the trust gate and every other `session/new` rule still apply.
//!   A Claude/Codex chat in a store no profile uses (a subrouter account
//!   home) adopts on its family's profile, which acpmux runs on that store
//!   (cx-vx54).
//! - `terminal`: every other resumable chat. The client opens a terminal tab
//!   that runs `argv` with `env` in `cwd`; a Claude/Codex chat when no
//!   profile of its family is configured.
//! - `readOnly`: no resume path; the client shows the transcript.
//!
//! A chat opens in its recorded folder. When the folder is gone, guarded or
//! unknown, the plan has `cwd: null` and `needsFolder` (AGENT-CWD rule): the
//! client asks and calls again with the folder the person picked. It never
//! falls back to the home folder.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, IndexedChat, Resume};
use serde_json::{Value, json};

use crate::adopt::HarnessHomes;
use crate::config::{Config, HarnessKind, derive_family, store_family};
use cmux_json::JsonSet as _;

/// A configured profile and the harness stores it resumes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoreProfile {
    pub name: String,
    pub family: String,
    /// The Claude home (`CLAUDE_CONFIG_DIR`) for a Claude-family profile.
    pub claude: Option<PathBuf>,
    /// The Codex home (`CODEX_HOME`) for a Codex-family profile.
    pub codex: Option<PathBuf>,
}

/// The Claude, Codex and OpenCode profiles that can adopt, with the stores their
/// spawn env names: the profile's env, then its own defaults entry, then its
/// family's defaults, then the daemon's homes.
pub fn store_profiles(config: &Config, homes: &HarnessHomes) -> Vec<StoreProfile> {
    let none = BTreeMap::new();
    config
        .harnesses
        .iter()
        .filter(|(_, profile)| profile.kind != HarnessKind::Terminal)
        .filter_map(|(name, profile)| {
            // Any Claude Code profile (`claude-sr2`) reads Claude's store and can adopt from it.
            let family = store_family(name, profile);
            if family != "claude" && family != "codex" && family != "opencode" {
                return None;
            }
            // Its spawn env: the defaults of its own family (`config::defaults_for`).
            let own = derive_family(name, profile);
            let layers = [
                config.defaults.get(&own).map_or(&none, |d| &d.env),
                config.defaults.get(name).map_or(&none, |d| &d.env),
                &profile.env,
            ];
            let stores = homes.with_env(&layers);
            Some(StoreProfile {
                name: name.clone(),
                claude: (family == "claude").then_some(stores.claude),
                codex: (family == "codex").then_some(stores.codex),
                family,
            })
        })
        .collect()
}

/// The open plan of `chat`. `given_cwd` is a folder the person picked.
pub fn plan_open(
    chat: &IndexedChat,
    profiles: &[StoreProfile],
    given_cwd: Option<&Path>,
    home: &Path,
) -> Result<Value, String> {
    let entry = &chat.entry;
    let (cwd, needs_folder) = folder(entry.cwd.as_deref(), given_cwd, home)?;
    let key = super::key_text(&entry.key());
    let mut plan = json!({
        "key": key,
        "cwd": cwd,
        "needsFolder": needs_folder.map(|reason| json!({"reason": reason})),
    });
    let bare = crate::adopt::is_bare_id(&entry.session_id);
    match (&entry.resume, bare) {
        (Resume::Adopt, true) => {
            let stores = store_dirs(chat);
            // A store no profile uses (a subrouter account home, a root the
            // person added) still adopts, on the family's profile: acpmux
            // runs it on that store, found in its own index (cx-vx54).
            let profile = adopting_profile(entry.harness, &stores, profiles)
                .or_else(|| family_profile(entry.harness, profiles));
            if let Some(profile) = profile {
                let adopt = json!({"harness": profile, "agentSessionId": entry.session_id});
                plan.set("kind", json!("adopt"));
                // The profile is named freely; the family says what the chat is (View Only).
                plan.set("family", json!(adapter_family(entry.harness)));
                plan.set("adopt", adopt.clone());
                if let Some(cwd) = &cwd {
                    plan.set(
                        "sessionNew",
                        json!({
                            "cwd": cwd,
                            "mcpServers": [],
                            "_meta": {"acpmux": {"harness": profile, "adopt": adopt}},
                        }),
                    );
                }
            } else {
                let (argv, env) = terminal_resume(entry.harness, &entry.session_id, &stores, home);
                plan.set("kind", json!("terminal"));
                plan.set("terminal", json!({"argv": argv, "env": env}));
            }
        }
        (Resume::Argv { argv, .. }, true) => {
            plan.set("kind", json!("terminal"));
            plan.set("terminal", json!({"argv": argv, "env": {}}));
        }
        // An id that is not a bare id never reaches a command line.
        (Resume::ReadOnly, _) | (_, false) => {
            plan.set("kind", json!("readOnly"));
            plan.set("readOnly", json!({"path": entry.source_path}));
        }
    }
    Ok(plan)
}

/// The folder to open in, or why the person must pick one.
fn folder(
    recorded: Option<&str>,
    given: Option<&Path>,
    home: &Path,
) -> Result<(Option<PathBuf>, Option<String>), String> {
    if let Some(given) = given {
        if !given.is_absolute() || !given.is_dir() {
            return Err(format!("cwd {} is not a folder", given.display()));
        }
        return Ok((Some(given.to_path_buf()), None));
    }
    let Some(recorded) = recorded.map(PathBuf::from) else {
        return Ok((None, Some("the chat recorded no folder; pick one".to_owned())));
    };
    if let Some(reason) = crate::protected_folders::refusal_in(&recorded, Some(home)) {
        return Ok((None, Some(reason)));
    }
    if !recorded.is_dir() {
        let reason =
            format!("the chat's folder {} was deleted or moved; pick one", recorded.display());
        return Ok((None, Some(reason)));
    }
    Ok((Some(recorded), None))
}

/// The harness homes of the roots that hold the chat (a Claude root is
/// `<home>/projects`; a Codex root is the home), the root of the chat's own
/// file first.
pub(crate) fn store_dirs(chat: &IndexedChat) -> Vec<PathBuf> {
    let prefix = format!("{}:", chat.entry.harness.id());
    let source = std::fs::canonicalize(&chat.entry.source_path).ok();
    let mut roots: Vec<PathBuf> =
        chat.roots.iter().filter_map(|id| id.strip_prefix(&prefix)).map(PathBuf::from).collect();
    roots.sort_by_key(|root| !source.as_ref().is_some_and(|s| s.starts_with(root)));
    roots
        .into_iter()
        .filter_map(|root| match chat.entry.harness {
            AdapterKind::ClaudeCode => root.parent().map(Path::to_path_buf),
            _ => Some(root),
        })
        .collect()
}

/// The acpmux family of a chat that adopts: `claude`, `codex` or `opencode`.
fn adapter_family(harness: AdapterKind) -> Option<&'static str> {
    match harness {
        AdapterKind::ClaudeCode => Some("claude"),
        AdapterKind::Codex => Some("codex"),
        AdapterKind::OpenCode => Some("opencode"),
        _ => None,
    }
}

/// The family's profile when none's store holds the chat: the one named like
/// the family first, then the others in name order.
fn family_profile(harness: AdapterKind, profiles: &[StoreProfile]) -> Option<&str> {
    // OpenCode keeps every chat in one data dir: any opencode profile loads it.
    let family = adapter_family(harness)?;
    profiles
        .iter()
        .filter(|profile| profile.family == family)
        .min_by_key(|profile| (profile.name != family, profile.name.clone()))
        .map(|profile| profile.name.as_str())
}

/// The profile whose store holds the chat: the one named like the family
/// first, then the others in name order.
fn adopting_profile<'a>(
    harness: AdapterKind,
    stores: &[PathBuf],
    profiles: &'a [StoreProfile],
) -> Option<&'a str> {
    let family = match harness {
        AdapterKind::ClaudeCode => "claude",
        AdapterKind::Codex => "codex",
        _ => return None,
    };
    let real = |path: &Path| std::fs::canonicalize(path).ok();
    let stores: Vec<PathBuf> = stores.iter().filter_map(|store| real(store)).collect();
    let mut candidates: Vec<&StoreProfile> =
        profiles.iter().filter(|profile| profile.family == family).collect();
    candidates.sort_by_key(|profile| (profile.name != family, profile.name.clone()));
    candidates
        .into_iter()
        .find(|profile| {
            let home = if family == "claude" { &profile.claude } else { &profile.codex };
            home.as_deref().and_then(real).is_some_and(|home| stores.contains(&home))
        })
        .map(|profile| profile.name.as_str())
}

/// `claude --resume <id>` / `codex resume <id>` with the chat's store as env
/// when it is not the harness's default home (setting `CLAUDE_CONFIG_DIR` to
/// `~/.claude` would move Claude's own config file).
fn terminal_resume(
    harness: AdapterKind,
    id: &str,
    stores: &[PathBuf],
    home: &Path,
) -> (Vec<String>, BTreeMap<String, PathBuf>) {
    let (argv, var, default) = match harness {
        AdapterKind::Codex => (["codex", "resume"], "CODEX_HOME", home.join(".codex")),
        _ => (["claude", "--resume"], "CLAUDE_CONFIG_DIR", home.join(".claude")),
    };
    let mut argv: Vec<String> = argv.iter().map(|s| (*s).to_owned()).collect();
    argv.push(id.to_owned());
    let mut env = BTreeMap::new();
    let default = std::fs::canonicalize(&default).unwrap_or(default);
    if let Some(store) = stores.first()
        && std::fs::canonicalize(store).unwrap_or_else(|_| store.clone()) != default
    {
        env.insert(var.to_owned(), store.clone());
    }
    (argv, env)
}
