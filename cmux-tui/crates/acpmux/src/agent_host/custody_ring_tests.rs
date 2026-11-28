use super::*;

#[tokio::test]
async fn a_replacement_reader_recovers_a_partial_frame_with_a_key_prefix() {
    use tokio::io::AsyncReadExt as _;

    let dir = tempfile::tempdir().unwrap();
    let ring = std::sync::Arc::new(Ring::create(dir.path()).unwrap());
    let mut fds = [-1; 2];
    // SAFETY: pipe fills both owned descriptors on success.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    let reader = unsafe { OwnedFd::from_raw_fd(fds[0]) };
    let mut writer = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fds[1]) });
    let mut original = RingPipe::new(dup(reader.as_raw_fd()).unwrap(), ring.clone(), 0).unwrap();
    let prefix = b"{\"text\":\"fixture-";
    writer.write_all(prefix).unwrap();
    let mut partial = [0; 1];
    // The pipe was consumed before the first byte was returned. The replacement must be
    // able to replay the unpublished suffix as well as the byte the old reader returned.
    original.read_exact(&mut partial).await.unwrap();
    assert_eq!(partial, [prefix[0]]);
    assert_eq!(ring.end().unwrap(), prefix.len() as u64);
    drop(original);

    writer.write_all(b"ordinary\"}\n").unwrap();
    drop(writer);
    let mut replacement = RingPipe::new(reader, ring, 0).unwrap();
    let mut replay = Vec::new();
    replacement.read_to_end(&mut replay).await.unwrap();
    assert_eq!(replay.as_slice(), b"{\"text\":\"fixture-ordinary\"}\n");
}
