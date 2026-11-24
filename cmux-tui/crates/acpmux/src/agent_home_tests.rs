use super::*;
use serde_json::json;

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// A head at revision 1 carrying `CLAUDE.md` and one memory note, as `cmux link memory` leaves it.
fn seeded() -> (tempfile::TempDir, Head) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join("blobs/g1")).unwrap();
    std::fs::create_dir_all(root.join("proposals")).unwrap();
    let mut manifest = BTreeMap::new();
    for (path, text) in
        [(".claude/CLAUDE.md", "be brief\n"), (".claude/projects/p/memory/MEMORY.md", "- a note\n")]
    {
        let sha = blob(root, text);
        manifest.insert(path.to_string(), Item { sha256: sha, mode: 0o644 });
    }
    let read = HeadRead { generation: 1, head: Some(Accepted { revision: 1, manifest }) };
    write_json(&root.join("head.json"), &read).unwrap();
    let head = Head::at(root.to_path_buf());
    (dir, head)
}

fn blob(root: &Path, text: &str) -> String {
    let sha = hash(text.as_bytes());
    std::fs::write(root.join("blobs/g1").join(&sha), text).unwrap();
    sha
}

fn propose(root: &Path, id: &str, base: u64, patch: Vec<(&str, Option<&str>)>) {
    let patch = patch
        .into_iter()
        .map(|(path, text)| {
            (path.to_string(), text.map(|t| Item { sha256: blob(root, t), mode: 0o644 }))
        })
        .collect();
    let proposal = Proposal { device: "laptop".into(), generation: 1, base_revision: base, patch };
    write_json(&root.join("proposals").join(format!("{id}.json")), &proposal).unwrap();
}

const A: &str = "aaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbb";

#[test]
fn an_absent_head_lists_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let listing = Head::at(dir.path().to_path_buf()).listing().unwrap();
    assert_eq!(listing["configured"], false);
    assert_eq!(listing["carried"], json!([]));
}

#[test]
fn the_listing_shows_carried_files_and_each_proposal_with_its_diff() {
    let (dir, head) = seeded();
    propose(
        dir.path(),
        A,
        1,
        vec![
            (".claude/CLAUDE.md", Some("be brief\nbe kind\n")),
            (".claude/projects/p/memory/new.md", Some("fresh\n")),
            (".claude/projects/p/memory/MEMORY.md", None),
        ],
    );
    let listing = head.listing().unwrap();
    assert_eq!(listing["configured"], true);
    assert_eq!(listing["revision"], 1);
    let carried = listing["carried"].as_array().unwrap();
    assert_eq!(carried.len(), 2);
    assert_eq!(carried[0]["path"], ".claude/CLAUDE.md");
    assert_eq!(carried[0]["kind"], "instructions");
    assert_eq!(carried[0]["bytes"], 9);
    assert_eq!(carried[1]["kind"], "memory");
    let proposal = &listing["proposals"][0];
    assert_eq!(proposal["id"], A);
    assert_eq!(proposal["device"], "laptop");
    assert_eq!(proposal["baseRevision"], 1);
    let entries = proposal["entries"].as_array().unwrap();
    let by = |path: &str| entries.iter().find(|e| e["path"] == path).unwrap().clone();
    let changed = by(".claude/CLAUDE.md");
    assert_eq!(changed["change"], "change");
    assert!(changed["diff"].as_str().unwrap().contains("+be kind"), "{changed}");
    assert_eq!(by(".claude/projects/p/memory/new.md")["change"], "add");
    let removed = by(".claude/projects/p/memory/MEMORY.md");
    assert_eq!(removed["change"], "remove");
    assert!(removed["diff"].as_str().unwrap().contains("-- a note"), "{removed}");
}

#[test]
fn accepting_moves_the_head_and_a_stale_proposal_is_refused() {
    let (dir, head) = seeded();
    propose(dir.path(), A, 1, vec![(".claude/CLAUDE.md", Some("v2\n"))]);
    propose(dir.path(), B, 1, vec![(".claude/AGENTS.md", Some("x\n"))]);
    let reply = head.resolve(&[A.into(), B.into()], &[]).unwrap();
    assert_eq!(reply["accepted"], json!([A]));
    assert_eq!(reply["revision"], 2);
    assert_eq!(reply["refused"][0]["id"], B);
    let read = head.read().unwrap();
    let accepted = read.head.unwrap();
    assert_eq!(accepted.revision, 2);
    assert_eq!(accepted.manifest[".claude/CLAUDE.md"].sha256, hash(b"v2\n"));
    assert!(!accepted.manifest.contains_key(".claude/AGENTS.md"));
    assert!(!dir.path().join(format!("proposals/{A}.json")).exists());
    // The refused one stays for its device to see; accepting it again is refused again.
    assert!(dir.path().join(format!("proposals/{B}.json")).exists());
    let again = head.resolve(&[A.into()], &[]).unwrap();
    assert_eq!(again["accepted"], json!([]));
}

#[test]
fn dropping_removes_the_proposal_and_leaves_the_head() {
    let (dir, head) = seeded();
    propose(dir.path(), A, 1, vec![(".claude/CLAUDE.md", Some("v2\n"))]);
    let reply = head.resolve(&[], &[A.into()]).unwrap();
    assert_eq!(reply["dropped"], json!([A]));
    assert_eq!(reply["revision"], 1);
    assert!(head.listing().unwrap()["proposals"].as_array().unwrap().is_empty());
}

#[test]
fn an_id_that_is_a_path_is_refused() {
    let (_dir, head) = seeded();
    let reply = head.resolve(&["../head".into()], &["../../x".into()]).unwrap();
    assert_eq!(reply["refused"].as_array().unwrap().len(), 2);
    assert!(head.read().unwrap().head.is_some());
}

#[test]
fn a_long_diff_is_cut() {
    let old = "";
    let new: String = (0..5000).map(|n| format!("line {n}\n")).collect();
    let text = diff("f", old, &new);
    assert!(text.len() <= DIFF_MAX + 64);
    assert!(text.ends_with("KB\n"));
}
