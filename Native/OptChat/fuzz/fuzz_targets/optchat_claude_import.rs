//! `optchat-chief import-claude-code` (`claude_import::convert_projects`): the
//! user's Claude Code transcripts (`projects/<project>/<session>.jsonl`), read
//! as the import reads them. The input is up to four sessions, split on NUL
//! bytes, written into one project directory per process.
//!
//! Invariants past "no panic": every session that yields items starts with
//! its note, and the items match the counts the dry run prints (one note per
//! session, `user` user items, `replies` plus `tool_summaries` AI items);
//! `first` is never after `last`.
#![no_main]

use std::path::PathBuf;
use std::sync::LazyLock;

use libfuzzer_sys::fuzz_target;
use optchat_chief::claude_import::convert_projects;
use optchat_core::Kind;

/// The most sessions one input writes.
const MAX_SESSIONS: usize = 4;

/// `projects/` of this process: parallel jobs never read another's files.
static PROJECTS: LazyLock<PathBuf> = LazyLock::new(|| {
    let root = std::env::temp_dir().join(format!("optchat-fuzz-import-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("project")).expect("a project dir");
    root
});

fuzz_target!(|data: &[u8]| {
    let project = PROJECTS.join("project");
    for n in 0..MAX_SESSIONS {
        let _ = std::fs::remove_file(project.join(format!("s{n}.jsonl")));
    }
    // read_to_string refuses a file that is not UTF-8; the import then fails
    // as a whole, which is its answer for such a directory.
    for (n, session) in data.split(|b| *b == 0).take(MAX_SESSIONS).enumerate() {
        std::fs::write(project.join(format!("s{n}.jsonl")), session).expect("a session file");
    }
    let Ok((items, stats)) = convert_projects(&PROJECTS) else {
        return;
    };
    let count = |kind: Kind| items.iter().filter(|item| item.kind == kind).count();
    assert_eq!(
        count(Kind::Note),
        stats.sessions,
        "one note per session: {stats:?}"
    );
    assert_eq!(count(Kind::User), stats.user, "user items: {stats:?}");
    assert_eq!(
        count(Kind::Ai),
        stats.replies + stats.tool_summaries,
        "AI items: {stats:?}"
    );
    assert_eq!(
        items.len(),
        stats.sessions + stats.user + stats.replies + stats.tool_summaries
    );
    if let Some(first) = items.first() {
        assert_eq!(
            first.kind,
            Kind::Note,
            "the first item is not a session note"
        );
    }
    if let (Some(first), Some(last)) = (&stats.first, &stats.last) {
        assert!(first <= last, "first {first} after last {last}");
    }
});
