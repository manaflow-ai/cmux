use super::*;

/// One process stands in for both daemons: the listeners it offers come back through the side
/// socket as the same sockets (a connect to the original path is accepted by the copy).
#[test]
fn listeners_go_through_the_side_socket() {
    let dir = cmux_unix_socket::short_test_dir("lho");
    let home = dir.path().to_path_buf();
    let sock = home.join("a.sock");
    let unix = UnixListener::bind(&sock).unwrap();
    let tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = tcp.local_addr().unwrap();
    offer(unix.as_fd(), Some(tcp.as_fd()));
    let side = Side::open(&home).unwrap();
    let path = side.path().to_path_buf();
    assert!(hand(&home, &home.join("elsewhere.sock"), std::process::id(), false).is_err());
    let sent = hand(&home, &path, std::process::id(), false).unwrap();
    assert_eq!(sent, ["unix", "ws"]);
    side.receive(&["unix".into(), "ws".into()], Some(std::process::id()));
    assert!(!path.exists(), "the side socket is removed once used");
    let got = take_received();
    drop((unix, tcp));
    let got_unix = got.unix.unwrap();
    assert!(serves_path(&got_unix, &sock));
    let _c = UnixStream::connect(&sock).unwrap();
    got_unix.accept().unwrap();
    let _t = std::net::TcpStream::connect(port).unwrap();
    got.ws.unwrap().accept().unwrap();
    HANDED_TO.store(0, Ordering::SeqCst);
}

/// update_handoff: a listener bound at `server/unix_bind.rs`'s staged name and moved into place
/// serves the socket it was moved to; a listener elsewhere does not.
#[test]
fn update_handoff_a_staged_listener_serves_its_socket() {
    let dir = cmux_unix_socket::short_test_dir("lhs");
    let home = dir.path().to_path_buf();
    let sock = home.join("acpmux.sock");
    let stage = home.join(".b1f0");
    std::fs::create_dir(&stage).unwrap();
    let staged = UnixListener::bind(stage.join("s")).unwrap();
    std::fs::rename(stage.join("s"), &sock).unwrap();
    assert!(serves_path(&staged, &sock));
    let other = UnixListener::bind(home.join("other.sock")).unwrap();
    assert!(!serves_path(&other, &sock));
    let odd = home.join(".bzz");
    std::fs::create_dir(&odd).unwrap();
    let odd_listener = UnixListener::bind(odd.join("s")).unwrap();
    assert!(!serves_path(&odd_listener, &sock));
}

/// The daemon binds its socket at a staging name and renames it into place
/// (`server::bind_unix`), and the kernel keeps the staging name: a handed listener bound that way
/// still serves the socket. Comparing only the bound name refused every one, and the start that
/// took over died binding again.
#[tokio::test]
async fn a_listener_bound_at_a_staging_name_serves_its_socket() {
    let dir = cmux_unix_socket::short_test_dir("lhs");
    let sock = dir.path().join("a.sock");
    let listener = crate::server::bind_unix(&sock).await.unwrap();
    let std_listener = listener.into_std().unwrap();
    let bound = std_listener.local_addr().unwrap().as_pathname().map(Path::to_path_buf).unwrap();
    assert_ne!(bound, sock, "bound at its staging name: {}", bound.display());
    assert!(serves_path(&std_listener, &sock));
    assert!(!serves_path(&std_listener, &dir.path().join("b").join("a.sock")));
    assert!(!staged_for(Path::new("/x/.bzz/s"), Path::new("/x/a.sock")));
    assert!(!staged_for(Path::new("/x/.b12/t"), Path::new("/x/a.sock")));
    assert!(staged_for(Path::new("/x/.b1f2/s"), Path::new("/x/a.sock")));
}
