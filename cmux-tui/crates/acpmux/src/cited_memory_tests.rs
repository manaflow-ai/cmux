use super::*;

fn idx(files: &[&str]) -> Index {
    Index::from_files(Path::new("/r"), files.iter().map(|f| (*f).to_owned()).collect(), true)
}

fn lines10(_: &Path) -> Option<usize> {
    Some(10)
}

fn c(path: &str, line: u32) -> Citation {
    Citation { path: path.to_owned(), line }
}

#[test]
fn cited_memory_is_off_by_default() {
    assert!(!enabled_with(None, None));
    assert!(!enabled_with(Some(&json!({})), None));
    let on = json!({"agents": {"harnessMagic": {"citedMemory": {"enabled": true}}}});
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(None, Some("1")));
    assert_eq!(crate::hub::harness_magic::setting_key(FEATURE), SETTING_ENABLED);
    assert_eq!(crate::hub::harness_magic::env_key(FEATURE), KILL_ENV);
}

#[test]
fn cited_memory_finds_path_line_citations() {
    let text = "see `./cmux-tui/src/a.rs:12` and .github/workflows/ci.yml:3, \
                not a.rs:4 (no slash), /abs/x.rs:9, ../up/x.rs:9, b/c.txt:2, x/y.rs:0, \
                http://host:80/p, again cmux-tui/src/a.rs:12";
    assert_eq!(citations(text), vec![c("cmux-tui/src/a.rs", 12), c(".github/workflows/ci.yml", 3)]);
}

#[test]
fn cited_memory_resolves_by_path_suffix_and_unique_name() {
    let i = idx(&[
        "cmux-tui/crates/acpmux/src/hub/mod.rs",
        "cmux-tui/crates/x/src/hub/mod.rs",
        "a/only.rs",
    ]);
    // As written.
    assert_eq!(i.check_with(&c("cmux-tui/crates/x/src/hub/mod.rs", 3), &lines10), Verdict::Ok);
    // A unique suffix.
    assert_eq!(i.check_with(&c("acpmux/src/hub/mod.rs", 3), &lines10), Verdict::Ok);
    // An abbreviated prefix, found by its unique name.
    assert_eq!(i.check_with(&c("S/only.rs", 3), &lines10), Verdict::Ok);
    // Two files end in it: never called stale.
    assert_eq!(i.check_with(&c("src/hub/mod.rs", 3), &lines10), Verdict::Unknown);
    // No file has it.
    assert_eq!(i.check_with(&c("gone/away.rs", 3), &lines10), Verdict::FileGone);
    // Past the end.
    assert_eq!(i.check_with(&c("a/only.rs", 11), &lines10), Verdict::LineGone(10));
}

#[test]
fn cited_memory_cut_short_index_is_unknown_not_gone() {
    let i = Index::from_files(Path::new("/r"), vec!["a/b.rs".into()], false);
    assert_eq!(i.check_with(&c("gone/away.rs", 3), &lines10), Verdict::Unknown);
}

#[test]
fn cited_memory_screens_facts_on_disk() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("src/hub")).unwrap();
    std::fs::write(dir.path().join("src/hub/mod.rs"), "1\n2\n3\n").unwrap();
    std::fs::create_dir_all(dir.path().join("target/debug")).unwrap();
    std::fs::write(dir.path().join("target/debug/built.rs"), "1\n").unwrap();
    let i = Index::of(dir.path());
    let facts = vec![
        "no citation here".to_owned(),
        "the hub starts at src/hub/mod.rs:3".to_owned(),
        "the hub ends at src/hub/mod.rs:40".to_owned(),
        "built output lives in target/debug/built.rs:1".to_owned(),
        "one live, one gone: src/hub/mod.rs:2 and src/old.rs:5".to_owned(),
    ];
    let (kept, record) = screen(facts, &i);
    assert_eq!(
        kept,
        vec![
            "no citation here",
            "the hub starts at src/hub/mod.rs:3",
            "one live, one gone: src/hub/mod.rs:2 and src/old.rs:5",
        ]
    );
    assert_eq!(
        record["dropped"],
        json!([
            "the hub ends at src/hub/mod.rs:40",
            "built output lives in target/debug/built.rs:1"
        ])
    );
    let verdicts: Vec<&str> = record["citations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["verdict"].as_str().unwrap())
        .collect();
    assert_eq!(verdicts, vec!["ok", "lineGone", "fileGone", "ok", "fileGone"]);
}

#[test]
fn cited_memory_counts_a_last_line_without_newline() {
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("x.rs");
    std::fs::write(&f, "a\nb").unwrap();
    assert_eq!(line_count(&f), Some(2));
    std::fs::write(&f, "").unwrap();
    assert_eq!(line_count(&f), Some(0));
}
