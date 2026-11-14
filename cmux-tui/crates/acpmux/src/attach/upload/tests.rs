use super::*;

#[test]
fn sizes_and_spans_read_plainly() {
    assert_eq!(human(2 << 30), "2.0 GiB");
    assert_eq!(human(512 << 20), "512.0 MiB");
    assert_eq!(human(21906), "21.4 KiB");
    assert_eq!(human(12), "12 bytes");
    assert_eq!(span(Duration::from_secs(12)), "12 s");
    assert_eq!(span(Duration::from_secs(200)), "3 min 20 s");
    assert_eq!(span(Duration::from_secs(3840)), "1 h 4 min");
}

/// Two sends of one file to one chat never share an upload: the second gets no record while
/// the first holds it, and gets it once the first lets go (a sender that ended).
#[test]
fn one_sender_at_a_time_holds_a_files_resume_record() {
    let dir = std::env::temp_dir().join(format!("amx-rec-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("big.bin");
    std::fs::write(&file, b"bytes").unwrap();
    let meta = std::fs::metadata(&file).unwrap();
    let records = dir.join("records");
    let first = Record::claim_in(&records, "chat", &file, &meta).expect("the first claim");
    assert!(first.write("01a17d93-859c-75a2-82f8-350749c86551", Some("tok")));
    assert!(Record::claim_in(&records, "chat", &file, &meta).is_none(), "held by the first");
    let other = Record::claim_in(&records, "other-chat", &file, &meta);
    assert!(other.is_some(), "another chat's record is its own");
    drop(first);
    let again = Record::claim_in(&records, "chat", &file, &meta).expect("let go");
    let saved = again.read().expect("the record");
    assert_eq!(saved, ("01a17d93-859c-75a2-82f8-350749c86551".into(), Some("tok".into())));
    assert!(again.forget());
    assert!(again.read().is_none());
    assert!(again.forget(), "a record already gone is forgotten");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A sender that ends lets go of its record even while another process shares the lock's
/// open file description, as a child forked but not yet exec'd does (in the test binary,
/// other tests fork such children at any moment, which made the test above fail on CI).
/// The child here is `sleep`, handed the lock's descriptor and nothing else: every other
/// descriptor the test binary opens is close-on-exec, so it holds no other test's lock.
#[cfg(unix)]
#[test]
fn a_shared_lock_descriptor_does_not_keep_an_ended_senders_record() {
    use std::os::unix::io::AsRawFd;
    use std::os::unix::process::CommandExt;
    let dir = std::env::temp_dir().join(format!("amx-rec-shared-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("big.bin");
    std::fs::write(&file, b"bytes").unwrap();
    let meta = std::fs::metadata(&file).unwrap();
    let records = dir.join("records");
    let first = Record::claim_in(&records, "chat", &file, &meta).expect("the first claim");
    let fd = first.lock.as_raw_fd();
    const SHARED: libc::c_int = 3;
    let mut sleep = std::process::Command::new("sleep");
    sleep.arg("30").stdin(std::process::Stdio::null());
    // SAFETY: between fork and exec the child calls only dup2 and fcntl, both
    // async-signal-safe. dup2 leaves the lock open across exec as descriptor 3; when the
    // lock already is 3, fcntl clears its close-on-exec flag instead.
    unsafe {
        sleep.pre_exec(move || {
            let ok = if fd == SHARED {
                libc::fcntl(fd, libc::F_SETFD, 0) == 0
            } else {
                libc::dup2(fd, SHARED) == SHARED
            };
            if ok { Ok(()) } else { Err(std::io::Error::last_os_error()) }
        });
    }
    let mut child = sleep.spawn().expect("sleep");
    drop(first);
    let again = Record::claim_in(&records, "chat", &file, &meta);
    let _ = child.kill();
    let _ = child.wait();
    assert!(again.is_some(), "the child's copy kept the ended sender's record");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Only the link losing a request is retried, never a refusal of the upload itself.
#[test]
fn only_a_lost_request_is_retried() {
    use crate::rpc::RpcError;
    let lost = |m: &str| link_failure(&RpcError::internal(m));
    assert!(lost("peer cosmic-gray timed out"));
    assert!(lost("peer cosmic-gray dropped the request"));
    assert!(lost("peer cosmic-gray connection closed"));
    let reason = |r: &str| RpcError::internal("x").with_data(json!({"reason": r}));
    assert!(link_failure(&reason("peer_unreachable")));
    assert!(link_failure(&reason("upload.offset")));
    assert!(!link_failure(&reason("upload.diskFull")));
    assert!(!link_failure(&reason("upload.unknown")));
    assert!(!link_failure(&reason("filePut.unsupported")));
    assert!(!lost("cannot append upload: Input/output error"));
    assert!(!link_failure(&RpcError::invalid_params("peer x timed out")));
}

/// A record whose upload is gone, or went to a peer that cannot say where it stands, starts
/// a fresh upload; any other refusal keeps the record for a later send.
#[test]
fn a_record_is_dropped_only_when_its_upload_cannot_be_resumed() {
    assert!(no_resume(Some("upload.unknown")));
    assert!(no_resume(Some("filePut.unsupported")));
    assert!(!no_resume(Some("upload.unreadable")));
    assert!(!no_resume(Some("upload.diskFull")));
    assert!(!no_resume(Some("peer_unreachable")));
    assert!(!no_resume(None));
}
