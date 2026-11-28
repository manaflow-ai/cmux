use super::*;

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|a| (*a).to_owned()).collect()
}

#[test]
fn the_exec_keeps_the_daemons_flags_but_not_its_descriptors_or_an_earlier_handoff() {
    let args = strings(&[
        "acp",
        "daemon",
        "run",
        "--ready-fd",
        "3",
        "--memory",
        "--person-key-fd=4",
        "--take-over",
        "--listen",
        "127.0.0.1:0",
        "--handoff-lock-fd",
        "7",
        "--handoff-unix-fd=8",
        "--handoff-ws-fd",
        "9",
        "--handoff-count",
        "2",
        "--dev",
    ]);
    let (run, rest) = split_run(&args);
    assert_eq!(run, 3);
    assert_eq!(rest, strings(&["--memory", "--listen", "127.0.0.1:0", "--dev"]));
    // No `run`: nothing is taken for the prefix.
    assert_eq!(split_run(&strings(&["daemon"])), (0, strings(&["daemon"])));
}

#[test]
fn a_check_passes_only_with_this_handoff_and_every_argument() {
    let line = check_line().to_string();
    assert_eq!(
        accepts(format!("a log line\n{line}\n").as_bytes()),
        Ok(crate::build_info::build().to_owned())
    );
    assert!(accepts(b"").is_err());
    assert!(accepts(b"usage: acpmux daemon\n").is_err());
    let older = serde_json::json!({"build": "x", "handoff": 1, "args": [LOCK_FD, UNIX_FD, COUNT]});
    assert!(accepts(older.to_string().as_bytes()).is_err());
    let other = serde_json::json!({"build": "x", "handoff": 2, "args": FLAGS});
    assert!(accepts(other.to_string().as_bytes()).is_err());
}

fn armed() -> Kept {
    let exec = Exec { program: "/x/acpmux".into(), arg0: "acpmux".into(), args: Vec::new() };
    Kept { armed: Some(exec), ..Kept::new() }
}

#[test]
fn only_a_stop_the_committing_request_began_execs_in_place() {
    // The request's check passed, it committed, and its own wake began the stop.
    let mut kept = armed();
    assert!(kept.commit());
    assert!(kept.confirm(true));
    // A signal began the stop a moment after the commit: v1's exit.
    let mut kept = armed();
    assert!(kept.commit());
    assert!(!kept.confirm(false));
    assert!(kept.armed.is_none());
    // The request failed after its check and never committed: a later plain stop exits.
    let mut kept = armed();
    assert!(!kept.confirm(true));
    // A stop under way: a commit after it is no handoff, and nothing was checked.
    let mut kept = armed();
    assert!(!kept.confirm(false));
    assert!(!kept.commit());
    assert!(!Kept::new().commit());
}

fn cloexec(fd: RawFd) -> bool {
    // SAFETY: F_GETFD only reads the descriptor's flags.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    flags >= 0 && flags & libc::FD_CLOEXEC != 0
}

#[test]
fn a_failed_exec_returns_its_error_and_leaves_the_descriptors_close_on_exec() {
    let (kept, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
    let fd = kept.as_raw_fd();
    assert!(cloexec(fd));
    let error = exec_with(
        Path::new("/nonexistent/acpmux-handoff-test"),
        OsStr::new("acpmux"),
        &strings(&["daemon", "run"]),
        &[fd],
    );
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
    assert!(cloexec(fd), "the descriptor stayed open across an exec");
}

#[test]
fn adoption_refuses_what_is_not_the_lock_or_a_listening_socket() {
    let dir = cmux_unix_socket::short_test_dir("amx-hof");
    let lock = dir.path().join("daemon.lock");
    let other = dir.path().join("other");
    std::fs::write(&lock, "").unwrap();
    std::fs::write(&other, "").unwrap();

    // Another file is not the lock; the lock file itself is, and its flock holds.
    let not_lock = OwnedFd::from(std::fs::File::open(&other).unwrap());
    assert!(adopt_lock(not_lock, &lock).is_err());
    let lock_fd = OwnedFd::from(std::fs::File::open(&lock).unwrap());
    assert!(adopt_lock(lock_fd, &lock).is_ok());

    // A file, a connected socket and a listener elsewhere are refused; the listener on the
    // socket path is taken.
    let socket = dir.path().join("s.sock");
    let file = OwnedFd::from(std::fs::File::open(&other).unwrap());
    assert!(adopt_unix(file, &socket).is_err());
    let (stream, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
    assert!(adopt_unix(OwnedFd::from(stream), &socket).is_err());
    let elsewhere = std::os::unix::net::UnixListener::bind(dir.path().join("e.sock")).unwrap();
    assert!(adopt_unix(OwnedFd::from(elsewhere), &socket).is_err());
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    assert!(adopt_unix(OwnedFd::from(listener), &socket).is_ok());

    // A TCP listener at another port, and a unix listener, are not the WebSocket listener.
    let tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = tcp.local_addr().unwrap().port();
    let elsewhere: SocketAddr =
        format!("127.0.0.1:{}", port.wrapping_add(1).max(1)).parse().unwrap();
    let tcp_fd = OwnedFd::from(tcp.try_clone().unwrap());
    assert!(adopt_tcp(tcp_fd, &[elsewhere]).is_err());
    let any: SocketAddr = "127.0.0.1:0".parse().unwrap();
    assert!(adopt_tcp(OwnedFd::from(tcp), &[any]).is_ok());
    let unix = std::os::unix::net::UnixListener::bind(dir.path().join("t.sock")).unwrap();
    assert!(adopt_tcp(OwnedFd::from(unix), &[any]).is_err());
}
