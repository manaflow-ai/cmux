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
//! `optchat-chief-<id>`, `optchat-chief-codex-<id>`, `optchat-chief-<brain>-<id>` for each
//! open-source brain in [`BRAINS`] (turns),
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

/// The open-source brains a Chief turn can run on (chief-cohesion OSS-LOCAL-BRAINS.md): the
/// acpmux family, and the env key that points the brain at its own home. The Chief owns that
/// home (`$MUX_HOME/optchat/brains/<family>`, optchat-chief `brain_home.rs`): it writes the
/// brain's config there (models through the team gateway, the brain's own scheduler and chat
/// channels off), so the person's own `~/.hermes` or `~/.openclaw` never runs a Chief turn and
/// a turn never changes them.
pub const BRAINS: [(&str, &str); 2] = [("hermes", "HERMES_HOME"), ("openclaw", "OPENCLAW_HOME")];

/// The `initialize` feature that says this daemon defines the brain turn presets and their
/// homes: a Chief puts a turn on a brain only on a daemon that has it, since an older one would
/// start the brain with the person's own home.
pub const BRAIN_PRESETS_FEATURE: &str = "chiefBrainPresets";

/// The brain home env of a turn or subagent of `family` for the Chief at `chief`, when the
/// family is an open-source brain ([`BRAINS`]).
/// Env a brain's processes need beside its home, from the home's path. Hermes keeps one gateway
/// daemon per OS user per host and serves every profile from it, found through
/// `HERMES_GATEWAY_LOCK_DIR` (default `$XDG_STATE_HOME/hermes/gateway-locks`): without its own
/// dir the Chief's Hermes attached to whatever Hermes gateway the user had (their own, with their
/// config and keys, or one left from an earlier Chief whose home is gone: every session/new then
/// answered storage_unavailable). optchat-chief `brain_gateway.rs` gives its gateway the same
/// dir, `<HERMES_HOME>/gateway-locks`.
pub fn brain_side_env(family: &str, home_dir: &str) -> Vec<(String, String)> {
    match family {
        "hermes" => vec![(
            "HERMES_GATEWAY_LOCK_DIR".to_owned(),
            Path::new(home_dir).join("gateway-locks").display().to_string(),
        )],
        _ => Vec::new(),
    }
}

pub fn brain_home_env(family: &str, chief: &Path) -> Option<(String, String)> {
    BRAINS.iter().find(|(f, _)| *f == family).map(|(f, key)| {
        ((*key).to_owned(), chief.join("optchat").join("brains").join(f).display().to_string())
    })
}

/// The home of the Chief whose record id is `chief` under the Chief home `root` (cmux-tui
/// `chief_brains::brain_home`: `c/<last 8 of the id, lowercased>`, whose `chief-id` file names
/// it); the Chief home itself for the default Chief, a new Chief (no id yet) or an id with no
/// directory of its own here.
fn chief_dir(root: &Path, chief: Option<&str>) -> PathBuf {
    let Some(id) = chief.map(str::trim).filter(|id| !id.is_empty()) else {
        return root.to_path_buf();
    };
    let tail = id.get(id.len().saturating_sub(8)..).unwrap_or(id).to_ascii_lowercase();
    let dir = root.join("c").join(tail);
    let owner = std::fs::read_to_string(dir.join("chief-id")).unwrap_or_default();
    if owner.trim() == id { dir } else { root.to_path_buf() }
}

/// The env a Chief editor's check of brain `family` runs with (`_acpmux/harness/doctor
/// {chief: true}`): this daemon's Chief home's brain home and the person's provider keys
/// blanked, as a Chief turn on it runs. None: `family` is no brain. Err: this daemon has no
/// Chief home, or the Chief has not written the brain's home yet (it does at each start).
pub fn brain_check_env(
    family: &str,
    ctx: &Context,
    chief: Option<&str>,
) -> Option<Result<BTreeMap<String, String>, String>> {
    BRAINS.iter().find(|(f, _)| *f == family)?;
    let Some(root) = ctx.chief_home.as_ref() else {
        return Some(Err(format!(
            "this acpmux has no Chief home ({CHIEF_MUX_HOME_ENV}); restart the Chief"
        )));
    };
    let home = &chief_dir(root, chief);
    let (key, dir) = brain_home_env(family, home)?;
    if !Path::new(&dir).is_dir() {
        return Some(Err(format!(
            "the Chief has not written its {family} home yet ({dir}); restart the Chief, then check again"
        )));
    }
    let mut env = BTreeMap::from([("MUX_HOME".to_owned(), home.display().to_string())]);
    env.extend(brain_side_env(family, &dir));
    env.insert(key, dir);
    for key in crate::login_env::PROVIDER_KEYS {
        env.insert(key.to_owned(), String::new());
    }
    Some(Ok(env))
}

/// A parsed built-in preset name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Builtin {
    role: Role,
    home_id: String,
}

/// optchat-chief `paths::home_id`: FNV-1a (32 bit) of the path's bytes,
/// 8 lowercase hex digits.
fn path_home_id(home: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for b in home.as_os_str().as_encoded_bytes() {
        hash ^= u32::from(*b);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

fn home_id(text: &str) -> Option<String> {
    (text.len() == 8 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
        .then(|| text.to_owned())
}

impl Builtin {
    /// A subagent preset (`optchat-sub-<id>`, `-claude`, `-codex`): its chats start at the
    /// person's start level, as a plain chat does (`hub/start_mode.rs`, cmux#27847).
    pub fn is_subagent(&self) -> bool {
        self.role == Role::Sub
    }
}

/// The built-in preset `name` names, if any.
pub fn parse(name: &str) -> Option<Builtin> {
    if let Some(rest) = name.strip_prefix("optchat-chief-codex-") {
        return home_id(rest).map(|home_id| Builtin { role: Role::Turn, home_id });
    }
    for (brain, _) in BRAINS {
        if let Some(rest) = name
            .strip_prefix("optchat-chief-")
            .and_then(|r| r.strip_prefix(brain)?.strip_prefix('-'))
        {
            return home_id(rest).map(|home_id| Builtin { role: Role::Turn, home_id });
        }
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

    /// The home of the Chief with `home_id`: the Chief home itself when the
    /// id is its own (the default Chief, and a daemon of one Chief, whose
    /// host hashes the same path string) or one of its `c/<id tail>`
    /// directories whose path has that id (the Chiefs the daemon's
    /// supervisor starts on the Chief home's shared acpmux, hq-6d
    /// 2026-10-14; the same path string the supervisor gives the Chief as
    /// `MUX_HOME`, so the ids match). An id of neither is refused: a preset
    /// must never borrow another Chief's homes (hq-6d 2026-10-14, fail
    /// closed). None: this daemon has no Chief home.
    fn home_of(&self, home_id: &str) -> Option<Result<PathBuf, String>> {
        let home = self.chief_home.as_ref()?;
        if path_home_id(home) == home_id {
            return Some(Ok(home.clone()));
        }
        let other = std::fs::read_dir(home.join("c")).ok().and_then(|entries| {
            entries
                .flatten()
                .map(|entry| home.join("c").join(entry.file_name()))
                .find(|dir| dir.is_dir() && path_home_id(dir) == home_id)
        });
        Some(other.ok_or_else(|| {
            format!(
                "built-in Chief preset: home id {home_id} is not a Chief of this daemon's Chief home {}",
                home.display()
            )
        }))
    }

    /// The home of the Chief with `home_id` ([`Context::home_of`]), refused
    /// when this daemon has no Chief home.
    fn chief(&self, home_id: &str) -> Result<PathBuf, String> {
        self.home_of(home_id).unwrap_or_else(|| {
            Err(format!(
                "a built-in codex preset needs {CHIEF_MUX_HOME_ENV} in this daemon's own environment"
            ))
        })
    }

    /// optchat-chief `Paths::root` of the Chief at `home`: `<home>/optchat`.
    fn optchat(home: &Path) -> PathBuf {
        home.join("optchat")
    }

    /// optchat-chief `chief_codex_in`: the Chief's own codex binary, else
    /// the one bundled next to this daemon. Never a PATH lookup.
    fn codex(&self, home: &Path) -> Option<String> {
        let own = home.join("optchat/codex/bin/codex");
        let bundled = self.bundle.as_ref().map(|b| b.join("chief-codex/codex"));
        std::iter::once(own).chain(bundled).find(|p| p.is_file()).map(|p| p.display().to_string())
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

/// Claude Code's switch for auto mode's server-side safety check
/// (2.1.319), at `0` in every Claude preset here: Claude Code's local
/// classifier judges each tool call. With the server check, a response
/// that carried no verdict (`server_no_result`) denied the call ("auto mode
/// has no safety result for this call"), with no local classifier to fall
/// back to, and a Chief ran none of its commands
/// (https://github.com/manaflow-ai/cmux/issues/37356). optchat-chief's
/// `session_dir::claude_session_env` sends the same to an older daemon.
pub const AUTO_MODE_SERVER_ENV: &str = "CLAUDE_CODE_AUTO_MODE_SERVER";

fn flags(env: &mut BTreeMap<String, String>, keys: &[&str], value: &str) {
    for key in keys {
        env.insert((*key).to_owned(), value.to_owned());
    }
}

/// The env of built-in `b` for a harness of `family` (`codex`, `claude`, ...).
pub fn env(b: &Builtin, family: &str, ctx: &Context) -> Result<BTreeMap<String, String>, String> {
    let codex = family == "codex";
    // An open-source brain takes neither Claude Code's nor codex's settings: its home (below)
    // holds its own.
    let brain = BRAINS.iter().any(|(f, _)| *f == family);
    let key = |role: &str| format!("optchat-{}-{role}", b.home_id);
    let mut env = BTreeMap::new();
    // The Chief the name's home id names: an id of no Chief of this
    // daemon's Chief home refuses the preset (fail closed).
    let home = ctx.home_of(&b.home_id).transpose()?;
    // A brain without the Chief's own home would run on the person's own (their keys, their
    // jobs): refused (fail closed).
    if brain && matches!(b.role, Role::Compact(_)) {
        return Err(format!("an open-source brain ({family}) does not run the Chief's compactor"));
    }
    if brain && matches!(b.role, Role::Turn | Role::Sub) && home.is_none() {
        return Err(format!(
            "a built-in {family} preset needs {CHIEF_MUX_HOME_ENV} in this daemon's own environment"
        ));
    }
    // A turn or subagent of a Chief on the Chief home's shared acpmux gets
    // its own Chief's MUX_HOME (`chief agents`, the `chief` tools), never
    // that of whoever started this daemon.
    if matches!(b.role, Role::Turn | Role::Sub)
        && let Some(home) = &home
    {
        env.insert("MUX_HOME".into(), home.display().to_string());
        if let Some((k, v)) = brain_home_env(family, home) {
            env.extend(brain_side_env(family, &v));
            env.insert(k, v);
            // A brain's models go through the gateway its home names, never a key of the
            // person's: every provider key the daemon would hand a multi-provider harness is
            // blanked (Hermes' side models fall back to OpenRouter or OpenAI when one is set).
            for key in crate::login_env::PROVIDER_KEYS {
                env.insert(key.to_owned(), String::new());
            }
        }
    }
    match b.role {
        Role::Turn => {
            flags(&mut env, &["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1");
            // Keep cmux and the folded acpmux coordinator tools: computer
            // use, secrets and session offers are subagent work, and their
            // tool names and instructions came after the turn's cache mark.
            env.insert(crate::agent_tools::SERVERS_ENV.into(), "cmux,acpmux".into());
            // That server lists only the Chief's tools and refuses the rest,
            // `cmux_exec` scripts included (fail closed without the Chief's env).
            env.insert(
                crate::agent_tools::MCP_TOOLS_ENV.into(),
                crate::agent_tools::CHIEF_TURN_TOOLS.into(),
            );
            if codex {
                env.insert("CODEX_PROMPT_CACHE_KEY".into(), key("turn"));
                let chief = ctx.chief(&b.home_id)?;
                env.insert(
                    "CODEX_HOME".into(),
                    Context::optchat(&chief).join("turn-codex").display().to_string(),
                );
                if let Some(path) = ctx.codex(&chief) {
                    env.insert("CODEX_PATH".into(), path);
                }
            } else if !brain {
                flags(&mut env, &["DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1");
                env.insert(AUTO_MODE_SERVER_ENV.into(), "0".into());
                env.insert("SUBROUTER_SESSION_KEY".into(), key("turn"));
                env.insert("SUBROUTER_SESSION_HEADER".into(), "1".into());
            }
        }
        Role::Compact(k) => {
            env.insert("ACPMUX_AGENT_TOOLS".into(), "0".into());
            if codex {
                let chief = ctx.chief(&b.home_id)?;
                let base = Context::optchat(&chief).join("compactor-codex");
                env.insert("HOME".into(), base.join("home").display().to_string());
                env.insert(
                    "CODEX_HOME".into(),
                    base.join(format!("slot-{k}")).display().to_string(),
                );
                env.insert("CODEX_PROMPT_CACHE_KEY".into(), key("compact"));
                if let Some(path) = ctx.codex(&chief) {
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
                        "DISABLE_AUTOUPDATER",
                    ],
                    "1",
                );
                env.insert(AUTO_MODE_SERVER_ENV.into(), "0".into());
                env.insert("SUBROUTER_SESSION_KEY".into(), key("compact"));
                env.insert("SUBROUTER_SESSION_HEADER".into(), "1".into());
            }
        }
        Role::Sub => {
            flags(&mut env, &["CLAUDE_CODE_DISABLE_AUTO_MEMORY", "OPTCHAT_SUBAGENT"], "1");
            if codex {
                env.insert("CODEX_PROMPT_CACHE_KEY".into(), key("sub"));
            } else if !brain {
                env.insert("DISABLE_AUTOUPDATER".into(), "1".into());
                env.insert(AUTO_MODE_SERVER_ENV.into(), "0".into());
                env.insert("SUBROUTER_SESSION_KEY".into(), key("sub"));
            }
            env.extend(ctx.pinned.clone());
            env.insert("PATH".into(), ctx.subagent_path());
        }
    }
    Ok(env)
}
