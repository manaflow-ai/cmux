use super::*;
use cmux_chat_index::Resume;

const ID: &str = "920ab030-d857-4a26-8afb-574eb70e8b2c";

fn chat(harness: AdapterKind, id: &str, path: &str) -> ChatEntry {
    ChatEntry {
        harness,
        session_id: id.to_owned(),
        title: None,
        title_source: None,
        cwd: Some("/Users/me/fun/prime-interface".into()),
        created_ms: None,
        updated_ms: 0,
        message_count: None,
        source_path: PathBuf::from(path),
        originator: None,
        archived: false,
        resume: Resume::Adopt,
    }
}

fn index() -> Vec<ChatEntry> {
    vec![
        chat(
            AdapterKind::ClaudeCode,
            ID,
            &format!("/Users/me/.claude/projects/-Users-me-fun-prime-interface/{ID}.jsonl"),
        ),
        chat(
            AdapterKind::ClaudeCode,
            "920ab999-0000-4000-8000-000000000000",
            "/Users/me/.claude/projects/-Users-me/920ab999-0000-4000-8000-000000000000.jsonl",
        ),
        chat(
            AdapterKind::Codex,
            "019a1b2c-3d4e-7f00-8000-0000000000aa",
            "/Users/me/.codex/sessions/2026/11/07/rollout-2026-11-07T10-00-00-019a1b2c-3d4e-7f00-8000-0000000000aa.jsonl",
        ),
    ]
}

fn key(harness: AdapterKind, id: &str) -> ChatKey {
    ChatKey { harness, session_id: id.to_owned() }
}

fn run(text: &str) -> Resolved {
    let chats = index();
    resolve(&normalize(text, Path::new("/Users/me")), &chats, |_| false)
}

#[test]
fn a_pasted_claude_session_id_finds_its_chat_in_any_project_folder() {
    assert_eq!(run(ID), Resolved::Found(key(AdapterKind::ClaudeCode, ID)));
    assert_eq!(
        run(&format!("  {} \n", ID.to_uppercase())),
        Resolved::Found(key(AdapterKind::ClaudeCode, ID))
    );
}

#[test]
fn a_codex_session_id_finds_its_chat() {
    let id = "019a1b2c-3d4e-7f00-8000-0000000000aa";
    assert_eq!(run(id), Resolved::Found(key(AdapterKind::Codex, id)));
    assert_eq!(run(&format!("codex resume {id}")), Resolved::Found(key(AdapterKind::Codex, id)));
}

#[test]
fn a_unique_id_start_finds_its_chat_and_a_shared_one_lists_them() {
    assert_eq!(run("920ab030"), Resolved::Found(key(AdapterKind::ClaudeCode, ID)));
    assert_eq!(
        run("019a"),
        Resolved::Found(key(AdapterKind::Codex, "019a1b2c-3d4e-7f00-8000-0000000000aa"))
    );
    assert_eq!(
        run("920ab"),
        Resolved::Ambiguous(vec![
            key(AdapterKind::ClaudeCode, ID),
            key(AdapterKind::ClaudeCode, "920ab999-0000-4000-8000-000000000000"),
        ])
    );
    assert_eq!(run("920"), Resolved::TooShort);
    assert_eq!(run("ffffffff"), Resolved::NotFound);
}

#[test]
fn a_transcript_path_or_command_or_key_finds_its_chat() {
    let found = Resolved::Found(key(AdapterKind::ClaudeCode, ID));
    assert_eq!(
        run(&format!("/Users/me/.claude/projects/-Users-me-fun-prime-interface/{ID}.jsonl")),
        found
    );
    assert_eq!(run(&format!("~/.claude/projects/-Users-me-fun-prime-interface/{ID}.jsonl")), found);
    assert_eq!(run(&format!("file:///Users/me/.claude/projects/x/{ID}.jsonl")), found);
    assert_eq!(run(&format!("claude --resume {ID}")), found);
    assert_eq!(run(&format!("claude -r '{ID}'")), found);
    assert_eq!(run(&format!("claude-code:{ID}")), found);
    let codex = "/Users/me/.codex/sessions/2026/11/07/rollout-2026-11-07T10-00-00-019a1b2c-3d4e-7f00-8000-0000000000aa.jsonl";
    assert_eq!(
        run(codex),
        Resolved::Found(key(AdapterKind::Codex, "019a1b2c-3d4e-7f00-8000-0000000000aa"))
    );
}

#[test]
fn a_transcript_file_the_index_lacks_is_recorded_not_refused() {
    let chats = index();
    let path = "/Users/me/elsewhere/.claude/projects/p/aaaabbbb-0000-4000-8000-000000000000.jsonl";
    assert_eq!(resolve(path, &chats, |_| true), Resolved::Unindexed(PathBuf::from(path)));
    assert_eq!(resolve(path, &chats, |_| false), Resolved::NotFound);
}

#[test]
fn a_full_id_the_index_lacks_is_found_in_the_claude_or_codex_store_on_disk() {
    let home = tempfile::tempdir().expect("tempdir");
    let projects = home.path().join(".claude/projects");
    let sessions = home.path().join(".codex/sessions");
    std::fs::create_dir_all(projects.join("-Users-me-fun-prime-interface")).expect("mkdir");
    std::fs::create_dir_all(sessions.join("2026/11/07")).expect("mkdir");
    let claude = projects.join(format!("-Users-me-fun-prime-interface/{ID}.jsonl"));
    std::fs::write(&claude, "{}\n").expect("write");
    let codex_id = "019a1b2c-3d4e-7f00-8000-0000000000aa";
    let codex = sessions.join(format!("2026/11/07/rollout-2026-11-07T10-00-00-{codex_id}.jsonl"));
    std::fs::write(&codex, "{}\n").expect("write");
    let roots = (vec![projects], vec![sessions]);
    assert_eq!(
        find_on_disk(&ID.to_uppercase(), &roots.0, &roots.1),
        Some((AdapterKind::ClaudeCode, claude))
    );
    assert_eq!(find_on_disk(codex_id, &roots.0, &roots.1), Some((AdapterKind::Codex, codex)));
    assert_eq!(find_on_disk("aaaabbbb-0000-4000-8000-000000000000", &roots.0, &roots.1), None);
    assert_eq!(find_on_disk("920ab030", &roots.0, &roots.1), None);
}
