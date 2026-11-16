//! A host record write never fails on a temporary file that an earlier writer left.

use super::*;

fn record(session: &str, nonce: &str) -> HostRecord {
    HostRecord {
        record_version: RECORD_VERSION,
        session_id: session.to_owned(),
        incarnation: "i".to_owned(),
        host_pid: std::process::id(),
        start_nonce: nonce.to_owned(),
        harness_pid: None,
        owner_token: "o".to_owned(),
        caller_token: None,
        protocol_min: PROTOCOL_MIN,
        protocol_max: PROTOCOL_MAX,
        host_build: "b".to_owned(),
        socket: PathBuf::from("/nonexistent.sock"),
    }
}

/// A host killed between the create and the rename of its record (SIGKILL, a power cut) leaves
/// `<session>.tmp-<pid>`. The pid comes back after a restart or a wrap, and the next host of the
/// same chat with that pid could not write its record: it killed its harness, so that chat's
/// agent never started.
#[test]
fn a_temporary_file_a_killed_host_left_never_stops_the_next_record() {
    let dir = tempfile::tempdir().unwrap();
    let path = record_path(dir.path(), "s1");
    let stale = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&stale, b"{\"half\":").unwrap();
    let want = record("s1", "00ff");
    write_record_atomic(&path, &want).expect("the record of the next host");
    let got: HostRecord = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(got, want);
}
