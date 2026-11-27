//! The Chief's and its subagents' folders carry no second copy of their
//! system prompt into a Claude session.
//!
//! acpmux's cross-harness fallback (cmux-tui/crates/acpmux/src/folder_instructions.rs)
//! sends a folder's AGENTS.md to a Claude session as a `<cmux-folder-context>` part when
//! the folder has none of Claude's own files (CLAUDE.md, .claude/CLAUDE.md,
//! CLAUDE.local.md). The host writes AGENTS.md in the session folder for a turn on
//! another harness (33 KB: the whole Chief system prompt) and in the subagent folder
//! (15 KB: the subagent system prompt), while a Claude turn or subagent already gets
//! that text as its preset's system prompt. Measured on Lawrence's Chief, Nov 15-18:
//! every turn (a fresh session each time) carried the 33 KB copy at the end of its
//! first message, about 8.6k more tokens written to the cache per turn; every Claude
//! subagent's first prompt carried the 15 KB one.
//!
//! Now both folders hold a one-line `.claude/CLAUDE.md` (Claude's own file, so the
//! fallback sends nothing) that says where the instructions are.

use optchat_chief::prompt::Tools;
use optchat_chief::session_dir::{SessionSetup, write, write_subagent};

/// The files acpmux takes as a Claude session's own (folder_instructions.rs `native`).
const CLAUDE_OWN: &[&str] = &["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"];

fn setup(paths: &optchat_chief::paths::Paths, tools: Tools) -> SessionSetup {
    let _ = paths;
    SessionSetup {
        exe: "/x/optchat-chief".into(),
        env: Default::default(),
        instructions: None,
        tools,
        user_env: Default::default(),
        profile_tool: false,
        chiefs_tool: false,
    }
}

fn own_file(dir: &std::path::Path) -> Option<String> {
    CLAUDE_OWN
        .iter()
        .map(|name| dir.join(name))
        .find(|p| p.is_file())
        .map(|p| std::fs::read_to_string(p).unwrap())
}

#[test]
fn a_claude_turn_folder_has_its_own_short_file_so_agents_md_is_not_sent_again() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    let tools = Tools::Cli(paths.bin.join("chief").display().to_string());
    write(&paths, &setup(&paths, tools)).unwrap();
    assert!(
        paths.session.join("AGENTS.md").is_file(),
        "kept for a codex turn"
    );
    let own = own_file(&paths.session).expect("a file Claude reads as its own");
    assert!(
        own.len() < 400,
        "a pointer, not a second prompt: {} bytes",
        own.len()
    );
    assert!(own.contains("system prompt"), "{own}");
}

#[test]
fn a_subagent_folder_has_its_own_short_file_so_agents_md_is_not_sent_again() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    let tools = Tools::Cli(paths.bin.join("chief").display().to_string());
    write_subagent(&paths, &setup(&paths, tools), "the subagent system prompt").unwrap();
    assert!(
        paths.subagent.join("AGENTS.md").is_file(),
        "kept for a codex subagent"
    );
    let own = own_file(&paths.subagent).expect("a file Claude reads as its own");
    assert!(own.len() < 400, "{} bytes", own.len());
    assert!(!own.contains("the subagent system prompt"), "{own}");
}

#[test]
fn the_old_layout_keeps_its_full_claude_md() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    write(&paths, &setup(&paths, Tools::Mcp)).unwrap();
    let full = std::fs::read_to_string(paths.session.join("CLAUDE.md")).unwrap();
    assert!(
        full.starts_with("You are Chief"),
        "{}",
        &full[..60.min(full.len())]
    );
}

#[test]
fn a_cached_claude_turn_keeps_its_own_pointer_after_the_full_file_is_removed() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    write(&paths, &setup(&paths, Tools::Mcp)).unwrap();
    // A cached turn carries the full instructions in its preset and removes
    // the old root file before starting the harness.
    optchat_chief::session_dir::set_claude_md(&paths.session, None).unwrap();
    assert!(!paths.session.join("CLAUDE.md").exists());
    assert!(paths.session.join("AGENTS.md").is_file());
    let own = own_file(&paths.session).expect("the cached Claude pointer");
    assert!(own.len() < 400, "a pointer, not a second prompt: {own}");
    assert!(own.contains("system prompt"), "{own}");
}

#[test]
fn the_old_layout_has_no_pointer_claiming_a_system_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    write(&paths, &setup(&paths, Tools::Mcp)).unwrap();
    // Without a preset system prompt the full text is the instructions, so the
    // pointer ("your instructions are your system prompt") must not be there.
    assert!(paths.session.join("CLAUDE.md").is_file());
    assert!(!paths.session.join(".claude").join("CLAUDE.md").exists());
}

#[test]
fn a_turn_without_the_preset_prompt_removes_the_pointer_again() {
    let dir = tempfile::tempdir().unwrap();
    let paths = optchat_chief::paths::Paths::new(dir.path());
    paths.create().unwrap();
    write(&paths, &setup(&paths, Tools::Mcp)).unwrap();
    optchat_chief::session_dir::set_claude_md(&paths.session, None).unwrap();
    assert!(paths.session.join(".claude").join("CLAUDE.md").is_file());
    optchat_chief::session_dir::set_claude_md(&paths.session, Some("You are Chief.")).unwrap();
    assert!(!paths.session.join(".claude").join("CLAUDE.md").exists());
    assert_eq!(
        std::fs::read_to_string(paths.session.join("CLAUDE.md")).unwrap(),
        "You are Chief."
    );
}
