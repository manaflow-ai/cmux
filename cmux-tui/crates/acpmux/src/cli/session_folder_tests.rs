use super::*;

/// A session on a peer started with no --cwd runs in a folder the peer
/// picked: the created line names the machine and that folder, so the
/// person knows where the agent works.
#[test]
fn the_created_line_names_the_folder_a_peer_picked() {
    let scratch = "/tmp/acpmux-peer-scratch-1000-01a1/api-work";
    assert_eq!(
        created_line("api-work", "01a17621d3c67800", Some("gcp-codex-lane-1"), Some(scratch)),
        format!("created api-work (01a17621) on gcp-codex-lane-1 in {scratch}")
    );
    // A peer that did not say: the machine only.
    assert_eq!(
        created_line("api-work", "01a17621d3c67800", Some("gcp-codex-lane-1"), None),
        "created api-work (01a17621) on gcp-codex-lane-1"
    );
    // Here, as before: the folder is the one the person is in.
    assert_eq!(created_line("x", "abc", None, Some("/home/u/p")), "created x (abc)");
}

#[test]
fn a_peer_start_with_no_cwd_sends_none() {
    assert_eq!(new_session_cwd(Some("gcp-codex-lane-1"), None).unwrap(), None);
    let given = PathBuf::from("/home/cmux/Projects/x");
    assert_eq!(new_session_cwd(Some("h"), Some(given.clone())).unwrap(), Some(given));
}
