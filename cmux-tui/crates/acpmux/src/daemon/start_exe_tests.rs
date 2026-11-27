use super::*;

fn c(exe: &str, t: Option<u64>) -> Candidate {
    Candidate { exe: PathBuf::from(exe), commit_time: t }
}

#[test]
fn the_own_binary_wins_unless_an_install_is_strictly_newer() {
    let own = c("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux", Some(200));
    // The air-blue case: ~/.local/bin holds an older build; the restart keeps its own.
    let older = [c("/Users/u/.local/bin/acpmux", Some(100))];
    assert_eq!(choose(&own, &older).0, None);
    // A tie keeps the own binary.
    assert_eq!(choose(&own, &[c("/Users/u/.local/bin/acpmux", Some(200))]).0, None);
    // Unknown commit times are never picked.
    assert_eq!(choose(&own, &[c("/Users/u/.local/bin/acpmux", None)]).0, None);
    // The newest strictly newer install wins, and the reason names it.
    let newer = [
        c("/Users/u/.local/bin/acpmux", Some(300)),
        c("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux", Some(400)),
    ];
    let (picked, why) = choose(&c("/Users/u/.local/bin/acpmux", Some(200)), &newer);
    assert_eq!(picked, Some(1));
    assert!(why.contains("cmux NIGHTLY.app") && why.contains("newer build"), "{why}");
}

#[test]
fn an_own_binary_of_unknown_commit_time_is_never_replaced() {
    let own = c("/opt/acpmux", None);
    let (picked, why) = choose(&own, &[c("/Users/u/.local/bin/acpmux", Some(400))]);
    assert_eq!(picked, None);
    assert!(why.contains("unknown"), "{why}");
    assert_eq!(choose(&c("/opt/acpmux", Some(0)), &[c("/b", Some(1))]).0, None);
}

#[test]
fn a_stamp_is_read_from_a_files_bytes_across_chunk_edges() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("acpmux");
    // The stamp straddles the first 1 MiB chunk's end.
    let mut bytes = vec![b'x'; (1 << 20) - 7];
    bytes.extend_from_slice(b"acpmux-commit-time=1794748257;tail");
    std::fs::write(&path, &bytes).unwrap();
    assert_eq!(commit_time_of(&path), Some(1_794_748_257));
    std::fs::write(&path, b"no stamp here").unwrap();
    assert_eq!(commit_time_of(&path), None);
    assert_eq!(commit_time_of(&dir.path().join("missing")), None);
    assert_eq!(embedded_commit_time(b"acpmux-commit-time=;acpmux-commit-time=5;"), Some(5));
}

#[test]
fn a_restart_won_by_an_older_build_is_stale() {
    let choice = Choice {
        this: SelfCommand::new(
            PathBuf::from("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux"),
            Vec::new(),
        ),
        commit_time: Some(200),
        why: String::new(),
    };
    let local = Path::new("/Users/u/.local/bin/acpmux");
    assert!(stale_winner(&choice, "9d9419a91", Some(local), Some("75d22c950"), Some(100)));
    // The same build elsewhere, a newer one, or an unknown one is not.
    assert!(!stale_winner(&choice, "9d9419a91", Some(local), Some("9d9419a91"), Some(100)));
    assert!(!stale_winner(&choice, "9d9419a91", Some(local), Some("abc"), Some(300)));
    assert!(!stale_winner(&choice, "9d9419a91", Some(local), Some("abc"), None));
    assert!(!stale_winner(&choice, "9d9419a91", None, Some("abc"), Some(100)));
    // The chosen file itself is never stale.
    assert!(!stale_winner(&choice, "x", Some(&choice.this.exe.clone()), Some("y"), Some(1)));
}
