use super::*;
use std::os::fd::AsFd as _;

/// Connects to `port` every few ms while `gap` runs: how many were refused, of how many.
fn connect_through(port: u16, gap: impl FnOnce()) -> (usize, usize, Vec<std::net::TcpStream>) {
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let dialer = {
        let stop = stop.clone();
        std::thread::spawn(move || {
            let (mut refused, mut total, mut open) = (0, 0, Vec::new());
            while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                total += 1;
                match std::net::TcpStream::connect(("127.0.0.1", port)) {
                    Ok(s) => open.push(s),
                    Err(_) => refused += 1,
                }
                std::thread::sleep(Duration::from_millis(2));
            }
            (refused, total, open)
        })
    };
    std::thread::sleep(Duration::from_millis(30));
    gap();
    std::thread::sleep(Duration::from_millis(30));
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    dialer.join().unwrap()
}

/// The restart as a service manager runs it: the old daemon's listener closes, 300 ms pass,
/// the next daemon serves the port. Before this every connect in between was refused (the
/// control below); with a keeper holding a copy none is, and the next daemon accepts each one
/// that queued.
#[test]
fn connects_across_a_restart_are_never_refused() {
    // Control: the old code's restart, close then bind again.
    let old = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = old.local_addr().unwrap().port();
    let mut slot = Some(old);
    let mut next = None;
    let (refused, total, _) = connect_through(port, || {
        drop(slot.take());
        std::thread::sleep(Duration::from_millis(300));
        next = Some(std::net::TcpListener::bind(("127.0.0.1", port)).unwrap());
    });
    assert!(refused > 0, "the control restart refused none of {total}: the gap is not measured");
    drop(next);

    // With a keeper.
    let dir = cmux_unix_socket::short_test_dir("lkp");
    let home = dir.path().to_path_buf();
    let daemon = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = daemon.local_addr().unwrap().port();
    let copy = daemon.as_fd().try_clone_to_owned().unwrap();
    widen_backlog(&copy);
    let socket = bind_held(&held_path(&home)).unwrap();
    let keeper = std::thread::spawn(move || {
        let held: [(&'static [u8; 4], OwnedFd); 1] = [(b"egrs", copy)];
        serve(&socket, &held, Duration::from_secs(10))
    });
    let mut taken = None;
    let (refused, total, open) = connect_through(port, || {
        drop(daemon);
        std::thread::sleep(Duration::from_millis(300));
        taken = take_held(&home).egress;
    });
    assert!(keeper.join().unwrap(), "the keeper handed its listener on");
    assert_eq!(refused, 0, "{refused} of {total} connects refused across the restart");
    let taken = taken.expect("the next daemon took the egress listener");
    assert_eq!(taken.local_addr().unwrap().port(), port);
    taken.set_nonblocking(true).unwrap();
    let mut accepted = 0;
    while taken.accept().is_ok() {
        accepted += 1;
    }
    assert_eq!(accepted, open.len(), "every connect is served by the next daemon");
}

/// A home with no keeper gives nothing, at once.
#[test]
fn no_keeper_takes_nothing() {
    let dir = cmux_unix_socket::short_test_dir("lkn");
    let got = take_held(dir.path());
    assert!(got.ws.is_none() && got.egress.is_none());
}
