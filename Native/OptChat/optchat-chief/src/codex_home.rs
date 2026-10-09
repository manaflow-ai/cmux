//! The codex compactor slots' private homes: one `CODEX_HOME` per slot with
//! only the user's routing and model keys, an isolation table, a symlinked
//! sign-in and one stable Chief installation id (split from compactor.rs).

use std::io;
use std::path::{Path, PathBuf};

use crate::compactor::private_dir;
use crate::paths::{Paths, home_id};

/// The env the cmux codex fork reads its `prompt_cache_key` from (in
/// place of the thread id, which is new for every acpmux session).
pub const CODEX_CACHE_KEY_ENV: &str = "CODEX_PROMPT_CACHE_KEY";

/// The Chief's codex `prompt_cache_key` for `role` (`turn`, `compact`):
/// `optchat-<home id>-<role>`. One key per prefix family, so every turn
/// (and every node) of one Chief lands on the cache the one before wrote.
pub fn codex_cache_key(home: &Path, role: &str) -> String {
    format!("optchat-{}-{role}", home_id(home))
}

/// The private, empty HOME every codex compactor slot runs with (under
/// `base`): codex finds user skills under `$HOME/.agents/skills` whatever
/// CODEX_HOME and the slot config say (codex ext/skills host_roots.rs), and
/// a session that offers skills fails the isolation check.
pub fn codex_private_home(base: &Path) -> PathBuf {
    base.join("home")
}

/// Compactor slot `k`'s own `CODEX_HOME` under `base`.
pub fn codex_slot_home(base: &Path, k: usize) -> PathBuf {
    base.join(format!("slot-{k}"))
}

/// The user's codex home: `CODEX_HOME` of the host, else `~/.codex`.
pub fn user_codex_home() -> PathBuf {
    if let Some(dir) = crate::cli::env("CODEX_HOME") {
        return PathBuf::from(dir);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into())
        .join(".codex")
}

/// Top-level keys of the user's codex config.toml a compactor slot keeps:
/// where its requests go (the team subrouter) and the model it asks for.
/// Nothing else: no MCP servers, profiles, hooks, notify, projects,
/// plugins or skills.
pub const CODEX_KEPT_KEYS: [&str; 8] = [
    "model",
    "model_provider",
    "model_providers",
    "openai_base_url",
    "chatgpt_base_url",
    "service_tier",
    "model_reasoning_effort",
    "model_verbosity",
];

/// A compactor slot's codex config.toml: the routing and model keys of the
/// user's (`user`, its text), then the isolation: no project AGENTS.md, no
/// skills (none loaded, none listed in the prompt), no apps, plugins,
/// memories, hooks, subagents or code mode, no history file.
pub fn codex_compactor_config(user: Option<&str>) -> Result<String, String> {
    let mut out = toml::Table::new();
    if let Some(text) = user {
        let table: toml::Table = text
            .parse()
            .map_err(|e| format!("reading the user's codex config.toml: {e}"))?;
        for key in CODEX_KEPT_KEYS {
            if let Some(value) = table.get(key) {
                out.insert(key.to_owned(), value.clone());
            }
        }
    }
    let isolation: toml::Table = r#"
project_doc_max_bytes = 0
suppress_unstable_features_warning = true

[history]
persistence = "none"

[features]
apps = false
plugins = false
memories = false
hooks = false
multi_agent = false
code_mode = false
skip_host_skill_discovery = true

[skills]
include_instructions = false

[skills.bundled]
enabled = false
"#
    .parse()
    .map_err(|e| format!("the compactor's isolation table: {e}"))?;
    out.extend(isolation);
    toml::to_string(&out).map_err(|e| format!("writing the compactor's codex config: {e}"))
}

/// Creates every compactor slot's `CODEX_HOME` (0700) under
/// `paths.compactor_codex` with `codex_compactor_config` of the user's
/// config.toml in `user_home`, and empties it (`wipe_codex_home`). When the
/// user has an auth.json, the slot's is a symlink to it: codex-acp refuses
/// a session without a sign-in (checked live 2026-10-04), and a copy whose
/// token refresh rotated the refresh token would sign the user out; codex
/// writes auth.json in place, so a refresh through the link updates the
/// user's own file.
pub fn prepare_codex_homes(paths: &Paths, user_home: &Path) -> Result<(), String> {
    let user = match std::fs::read_to_string(user_home.join("config.toml")) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("reading {}: {e}", user_home.display())),
    };
    let config = codex_compactor_config(user.as_deref())?;
    private_dir(&paths.compactor_codex)
        .map_err(|e| format!("creating {}: {e}", paths.compactor_codex.display()))?;
    let private_home = codex_private_home(&paths.compactor_codex);
    private_dir(&private_home)
        .and_then(|()| wipe_codex_home(&private_home))
        .map_err(|e| format!("preparing {}: {e}", private_home.display()))?;
    let id = chief_installation_id(&paths.compactor_codex)
        .map_err(|e| format!("the compactor's codex installation id: {e}"))?;
    for k in 0..crate::compactor::COMPACTOR_SESSIONS {
        let dir = codex_slot_home(&paths.compactor_codex, k);
        let made = private_dir(&dir)
            .and_then(|()| wipe_codex_home(&dir))
            .and_then(|()| {
                crate::session_dir::write_if_changed(&dir.join("config.toml"), config.as_bytes())
            })
            .and_then(|()| {
                crate::session_dir::write_if_changed(&dir.join("installation_id"), id.as_bytes())
            });
        made.map_err(|e| format!("preparing {}: {e}", dir.display()))?;
        link_auth(&dir, user_home).map_err(|e| format!("preparing {}: {e}", dir.display()))?;
    }
    Ok(())
}

/// The installation id every codex compactor slot sends: the subrouter
/// keeps one installation id on one account, and OpenAI's prompt cache is
/// per account, so slots with their own ids never read each other's prefix
/// (checked live 2026-10-04: 0 of 31.5k tokens with two ids, 30,464 with
/// one). Kept in `<base>/installation_id`, made once (a version 4 UUID, as
/// codex makes its own).
pub fn chief_installation_id(base: &Path) -> io::Result<String> {
    let path = base.join("installation_id");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let id = text.trim();
        if is_uuid(id) {
            return Ok(id.to_owned());
        }
    }
    let mut bytes = [0u8; 16];
    {
        use std::io::Read;
        std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let id = format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    );
    crate::session_dir::write_if_changed(&path, id.as_bytes())?;
    Ok(id)
}

fn is_uuid(text: &str) -> bool {
    text.len() == 36
        && text.char_indices().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

/// Points `<dir>/auth.json` at the user's auth.json, or removes it when the
/// user has none.
fn link_auth(dir: &Path, user_home: &Path) -> io::Result<()> {
    let link = dir.join("auth.json");
    let target = user_home.join("auth.json");
    if std::fs::read_link(&link).is_ok_and(|t| t == target) && target.exists() {
        return Ok(());
    }
    match std::fs::remove_file(&link) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    if target.exists() {
        std::os::unix::fs::symlink(&target, &link)?;
    }
    Ok(())
}

/// Files of a compactor `CODEX_HOME` that hold no chat text and survive
/// `wipe_codex_home`: its configuration, the link to the user's sign-in,
/// the Chief's installation id and codex's model catalog cache.
pub const CODEX_KEPT_FILES: [&str; 5] = [
    "config.toml",
    "auth.json",
    "installation_id",
    "models_cache.json",
    "version.json",
];

/// Removes everything in a compactor `CODEX_HOME` but `CODEX_KEPT_FILES`:
/// the node's rollout (`sessions/`), thread and log databases, history,
/// shell snapshots, the bundled skills codex unpacks.
pub fn wipe_codex_home(dir: &Path) -> io::Result<()> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        if CODEX_KEPT_FILES.iter().any(|k| name == *k) {
            continue;
        }
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            std::fs::remove_dir_all(&path)?;
        } else {
            std::fs::remove_file(&path)?;
        }
    }
    Ok(())
}
