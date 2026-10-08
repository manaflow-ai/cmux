//! How a chat opens again (ALL-CHATS-ON-DEVICE S5, C1). The daemon plans;
//! the client acts, so every open goes through the client's normal path:
//!
//! - `adopt`: a Claude/Codex chat in the store of a configured profile. The
//!   plan carries ready `session/new` params (that profile, `_meta.acpmux.adopt`),
//!   so the trust gate and every other `session/new` rule still apply.
//! - `terminal`: every other resumable chat. The client opens a terminal tab
//!   that runs `argv` with `env` in `cwd`. A Claude/Codex chat in a store no
//!   profile uses (a subrouter account home) gets that store as env.
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
use crate::config::{Config, HarnessKind, derive_family};

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

/// The Claude and Codex profiles that can adopt, with the stores their
/// spawn env names: the profile's env, then its own defaults entry, then its
/// family's defaults, then the daemon's homes.
pub fn store_profiles(config: &Config, homes: &HarnessHomes) -> Vec<StoreProfile> {
    let none = BTreeMap::new();
    config
        .harnesses
        .iter()
        .filter(|(_, profile)| profile.kind != HarnessKind::Terminal)
        .filter_map(|(name, profile)| {
            let family = derive_family(name, profile);
            if family != "claude" && family != "codex" {
                return None;
            }
            let layers = [
                config.defaults.get(&family).map_or(&none, |d| &d.env),
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
            if let Some(profile) = adopting_profile(entry.harness, &stores, profiles) {
                let adopt = json!({"harness": profile, "agentSessionId": entry.session_id});
                plan["kind"] = json!("adopt");
                plan["adopt"] = adopt.clone();
                if let Some(cwd) = &cwd {
                    plan["sessionNew"] = json!({
                        "cwd": cwd,
                        "mcpServers": [],
                        "_meta": {"acpmux": {"harness": profile, "adopt": adopt}},
                    });
                }
            } else {
                let (argv, env) = terminal_resume(entry.harness, &entry.session_id, &stores, home);
                plan["kind"] = json!("terminal");
                plan["terminal"] = json!({"argv": argv, "env": env});
            }
        }
        (Resume::Argv { argv, .. }, true) => {
            plan["kind"] = json!("terminal");
            plan["terminal"] = json!({"argv": argv, "env": {}});
        }
        // An id that is not a bare id never reaches a command line.
        (Resume::ReadOnly, _) | (_, false) => {
            plan["kind"] = json!("readOnly");
            plan["readOnly"] = json!({"path": entry.source_path});
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
fn store_dirs(chat: &IndexedChat) -> Vec<PathBuf> {
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
