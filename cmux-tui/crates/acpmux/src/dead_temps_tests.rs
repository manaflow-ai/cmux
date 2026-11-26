use super::pid_after;

#[test]
fn a_copy_is_named_by_its_writers_pid() {
    assert_eq!(pid_after("refusal.tmp-123-4", "refusal.tmp-"), Some(123));
    assert_eq!(pid_after("refusal.tmp-123", "refusal.tmp-"), Some(123));
    assert_eq!(pid_after("refusal.tmp-123-0192abcd-ef", "refusal.tmp-"), Some(123));
    assert_eq!(pid_after("refusal.tmp-notes", "refusal.tmp-"), None);
    assert_eq!(pid_after("refusal.tmp-12a-1", "refusal.tmp-"), None);
    assert_eq!(pid_after("refusal.tmp-", "refusal.tmp-"), None);
    assert_eq!(pid_after("refusal.tmp-0-1", "refusal.tmp-"), None);
    assert_eq!(pid_after("refusal.tmp-4194304-1", "refusal.tmp-"), Some(4_194_304));
    assert_eq!(pid_after("refusal.tmp-20261115", "refusal.tmp-"), None);
    assert_eq!(pid_after("consent.tmp-123-4", "refusal.tmp-"), None);
}

/// The detector for #44520: no writer names its temporary copy with a per-write counter
/// again (each new name is one more path fseventsd keeps). A cold archive's staging copy is
/// one per archive of a chat, not per write of a file, and stays.
#[test]
fn no_writer_mints_a_temporary_name_per_write() {
    fn walk(dir: &std::path::Path, found: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                walk(&path, found);
            } else if path.extension().is_some_and(|e| e == "rs") {
                let text = std::fs::read_to_string(&path).unwrap();
                if text.contains(concat!("tmp-{}-", "{n}")) {
                    found.push(path);
                }
            }
        }
    }
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut found = Vec::new();
    walk(&src, &mut found);
    found.retain(|path| !path.ends_with(std::path::Path::new("store").join("cold.rs")));
    assert!(found.is_empty(), "a temporary name with a per-write counter: {found:?}");
}
