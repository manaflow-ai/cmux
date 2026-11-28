use super::*;
use std::sync::Arc;

#[test]
fn terminal_agent_history_unindexed_uses_only_the_exact_file_in_an_enabled_root() {
    let home = tempfile::tempdir_in("/tmp").expect("synthetic home");
    let sources = ChatSources {
        home: home.path().to_owned(),
        acpmux_home: home.path().join("test-daemon-state"),
        env: Arc::new(|_| None),
        launch_roots: Vec::new(),
        user_roots: Vec::new(),
    };
    let key = ChatKey {
        harness: AdapterKind::ClaudeCode,
        session_id: "5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e".into(),
    };
    let cwd = Path::new("/original/project");
    let dir = home.path().join(".claude/projects").join(crate::adopt::project_dir_name(cwd));
    std::fs::create_dir_all(&dir).expect("project store");
    let path = dir.join(format!("{}.jsonl", key.session_id));
    std::fs::write(&path, b"{\"timestamp\":\"2026-11-12T07:00:00Z\"}\n").expect("transcript");
    let file = locate(None, &sources, &key, Some(cwd), true).expect("cold lookup");
    assert_eq!(file.path, path.canonicalize().unwrap());
    assert_eq!(file.created_ms, cmux_chat_index::parse_rfc3339_ms("2026-11-12T07:00:00Z"));

    // Opening an older page does not probe the header again.
    assert_eq!(locate(None, &sources, &key, Some(cwd), false).unwrap().created_ms, None);

    // Turning off discovery removes the default store from the set of allowed roots.
    let settings = ChatSettings { discovery: false, ..ChatSettings::default() };
    std::fs::create_dir_all(&sources.acpmux_home).expect("daemon home");
    std::fs::write(settings_path(&sources), serde_json::to_vec(&settings).unwrap()).unwrap();
    assert!(locate(None, &sources, &key, Some(cwd), false).is_none());
}
