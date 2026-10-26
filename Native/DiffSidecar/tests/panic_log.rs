//! A panic on any sidecar thread lands in `<root>/.sidecar-panics.jsonl` as
//! one `cmux-panic-log` line labeled `cmux-diff-sidecar` with its mode.

use cmux_diff_sidecar::panic_log;

#[test]
fn a_thread_panic_writes_one_line_in_the_root() {
    let root = std::env::temp_dir().join(format!("cmux-diff-panic-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let path = panic_log::log_path(&root);
    assert_eq!(path, root.join(".sidecar-panics.jsonl"));
    let _ = std::fs::remove_file(&path);
    // The same install as `main`.
    cmux_panic_log::install(path.clone(), panic_log::fields("rpc"), |_| false);

    let joined = std::thread::Builder::new()
        .name("sidecar-worker".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("sidecar test panic"))
        .unwrap()
        .join();
    assert!(joined.is_err());

    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert_eq!(lines[0]["process"], "cmux-diff-sidecar");
    assert_eq!(lines[0]["mode"], "rpc");
    assert_eq!(lines[0]["message"], "sidecar test panic");
    assert_eq!(lines[0]["thread"], "sidecar-worker");
    assert_eq!(lines[0]["test"], false);
    let _ = std::fs::remove_dir_all(&root);
}
