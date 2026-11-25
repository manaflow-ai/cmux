//! Where the Chief keeps its files under `$MUX_HOME`. The host lock is the one
//! `mux/host` and the P1 Rust Chief take, so the three never run together;
//! everything else lives under `optchat/`, apart from the files of `mux/host`.

use std::io;
use std::path::{Path, PathBuf};

/// `$MUX_HOME`, else `~/.cmux/mux` (tagged builds pass their own).
pub fn mux_home() -> PathBuf {
    if let Some(home) = crate::cli::env("MUX_HOME") {
        return PathBuf::from(home);
    }
    let user = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into());
    user.join(".cmux").join("mux")
}

/// A short id for a `MUX_HOME` (8 hex digits). Two homes sharing one acpmux
/// daemon tag their children and name their acpmux preset with it, so
/// neither takes the other's.
///
/// The id is given once and kept in `optchat/home-id`
/// ([`Paths::create`] writes it at the first host start): a home moved to
/// another folder or machine (`cmux chief move`) keeps its id, so the Chief
/// still finds its own acpmux sessions. Until it is written, the id is the
/// FNV-1a of the path, the value every home had before the file existed.
pub fn home_id(home: &Path) -> String {
    if let Some(pinned) = pinned_home_id(home) {
        return pinned;
    }
    path_home_id(home)
}

/// The id kept in `optchat/home-id`, when it is there and well formed.
fn pinned_home_id(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home_id_file(home)).ok()?;
    let id = text.trim();
    (id.len() == 8
        && id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
    .then(|| id.to_owned())
}

fn home_id_file(home: &Path) -> PathBuf {
    home.join("optchat").join("home-id")
}

/// Writes the home's id once (the path's FNV-1a, the id it already had);
/// an existing file is never changed. Atomic: a crash leaves no half id.
pub fn pin_home_id(home: &Path) -> io::Result<String> {
    if let Some(pinned) = pinned_home_id(home) {
        return Ok(pinned);
    }
    let id = path_home_id(home);
    let file = home_id_file(home);
    let tmp = file.with_extension(format!("tmp-{}", std::process::id()));
    {
        use std::io::Write;
        let mut out = std::fs::File::create(&tmp)?;
        out.write_all(format!("{id}\n").as_bytes())?;
        out.sync_all()?;
    }
    std::fs::rename(&tmp, &file)?;
    if let Some(dir) = file.parent()
        && let Ok(dir) = std::fs::File::open(dir)
    {
        let _ = dir.sync_all();
    }
    Ok(id)
}

/// FNV-1a of the home's path, 8 hex digits.
fn path_home_id(home: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for b in home.as_os_str().as_encoded_bytes() {
        hash ^= u32::from(*b);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paths {
    pub home: PathBuf,
    /// `$MUX_HOME/state/host.lock`, shared with mux/host (chief-mac.md section 2).
    pub host_lock: PathBuf,
    /// `$MUX_HOME/state/settle.json` while a turn waits for the compactor
    /// (settle_status.rs); the app shows it in the Chief conversation.
    pub settle_status: PathBuf,
    /// `$MUX_HOME/optchat`.
    pub root: PathBuf,
    /// The OptChat memory's directory (section 2): its single-writer `lock`,
    /// and the plain-text export of the database (`main/`, `tree/` JSONL
    /// day files, the format the memory was stored in before 2026-10-06),
    /// a git repository committed after every turn.
    pub chat: PathBuf,
    /// The memory database (`memory.sqlite3`): log, tree and host state.
    pub memory_db: PathBuf,
    /// The constant working directory of every turn session (section 7.2:
    /// a constant cwd keeps the harness prompt and tools byte-identical).
    pub session: PathBuf,
    /// The host's durable state before 2026-10-06 (`host.json`): imported
    /// into the memory database once, then renamed `host.json.imported`.
    pub state: PathBuf,
    /// The socket the `mcp` subcommand reaches the live memory on.
    pub tools_socket: PathBuf,
    /// Launchers on the turn session's PATH (`chief`).
    pub bin: PathBuf,
    /// The turn sessions' own Claude Code configuration (`CLAUDE_CONFIG_DIR`):
    /// no user CLAUDE.md, settings, hooks or auto-memory reach a turn.
    pub claude_config: PathBuf,
    /// The compactor sessions' own Claude Code configuration
    /// (`CLAUDE_CONFIG_DIR` of their required preset), separate from the
    /// turn sessions' so nothing a turn writes reaches a compactor call.
    pub compactor_config: PathBuf,
    /// The codex compactor sessions' own `CODEX_HOME`s, one per slot
    /// (`slot-<k>`): no user AGENTS.md, skills, plugins, hooks or MCP
    /// servers, and no transcript kept past its node.
    pub compactor_codex: PathBuf,
    /// The Chief's own codex binary (`$MUX_HOME/optchat/codex/bin/codex`):
    /// the cmux codex fork with its two helper binaries next to it, the
    /// `CODEX_PATH` of every codex session when installed.
    pub codex_bin: PathBuf,
    /// The user's own instructions file, the end of every turn's system
    /// prompt (section 7.2); read once per host start.
    pub instructions: PathBuf,
    /// The person profile (`optchat/person.md`): who the user is and how
    /// they want work done, short and user-editable; it heads the user's
    /// part of every system prompt, before `instructions` (prompt.rs
    /// `chief_instructions`). Not `profile.json`, the app's avatar file.
    pub person: PathBuf,
    /// Every subagent's working directory (section 9): its MCP servers
    /// (zoom and date only), project settings, and instructions file.
    pub subagent: PathBuf,
    /// The codex turns' own CODEX_HOME (codex_home::prepare_turn_codex_home).
    pub turn_codex: PathBuf,
    /// The monitoring trace (`trace.rs`).
    pub traces: PathBuf,
    /// The memory inspector's address and token for the app (inspect/http.rs), 0600.
    pub inspector: PathBuf,
    /// Share Screen with Chief's files (the app writes them; `screen_share.rs`):
    /// `inbox/` entries the brain turns into notes, `frames/` it names.
    pub screen: PathBuf,
}

impl Paths {
    pub fn new(home: &Path) -> Paths {
        let root = home.join("optchat");
        Paths {
            home: home.to_owned(),
            host_lock: home.join("state").join("host.lock"),
            settle_status: home.join("state").join("settle.json"),
            chat: root.join("chat"),
            memory_db: root.join("memory.sqlite3"),
            session: root.join("session"),
            state: root.join("host.json"),
            tools_socket: root.join("tools.sock"),
            bin: root.join("bin"),
            claude_config: root.join("claude"),
            compactor_config: root.join("compactor-claude"),
            compactor_codex: root.join("compactor-codex"),
            codex_bin: root.join("codex").join("bin").join("codex"),
            instructions: root.join("AGENTS.md"),
            person: root.join("person.md"),
            subagent: root.join("subagent"),
            turn_codex: root.join("turn-codex"),
            traces: root.join("traces"),
            inspector: root.join("inspector.json"),
            screen: root.join("screen"),
            root,
        }
    }

    /// Creates every directory the host writes into. `optchat/` is 0700: the
    /// memory holds everything the user pasted, and a Mac mini often has
    /// other accounts.
    pub fn create(&self) -> io::Result<()> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.root)?;
        std::fs::set_permissions(&self.root, std::fs::Permissions::from_mode(0o700))?;
        for dir in [&self.chat, &self.session, &self.bin, &self.claude_config] {
            std::fs::create_dir_all(dir)?;
        }
        if let Some(parent) = self.host_lock.parent() {
            std::fs::create_dir_all(parent)?;
        }
        pin_home_id(&self.home)?;
        Ok(())
    }
}
