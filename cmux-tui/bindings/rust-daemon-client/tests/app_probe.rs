//! The client's `client-hello` probe against a scripted server: the probe is
//! the first connection that says role `main`, which tells an app session's
//! owner that its app came. From then on the owner stops when no client is
//! connected and nothing else keeps it (cmux-tui `server/owner_keepers.rs`,
//! R-LIFECYCLE stage 1). So the probe must stay open until the daemon has
//! answered the client's long-lived connection: closed first, it left the
//! owner a moment with no client, in which it could stop and refuse the
//! long-lived connection.
// Unix sockets; the install key reaches the owner only on Unix.
#![cfg(unix)]

use cmux_daemon_client::{DaemonClient, DaemonConfig};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// What the scripted server saw.
#[derive(Debug, PartialEq, Eq)]
struct Seen {
    /// The probe was open when the long-lived connection sent its first
    /// request.
    probe_open_at_first_request: bool,
    /// The probe closed after the server answered that request.
    probe_closed_after: bool,
}

/// One accepted connection and its first line.
struct Connection {
    stream: UnixStream,
    first: Value,
}

fn accept(listener: &UnixListener) -> Connection {
    let (stream, _) = listener.accept().expect("accept");
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).expect("first line"), 0, "closed before a line");
    let first = serde_json::from_str(&line).expect("one JSON line");
    Connection { stream, first }
}

fn refuse(connection: &mut Connection) {
    let reply = json!({"id": connection.first["id"], "ok": false,
                       "error": {"code": "test.refused", "message": "refused by the test"}});
    writeln!(connection.stream, "{reply}").unwrap();
}

/// Whether the client still holds `stream` open (no end of file yet).
fn open(stream: &UnixStream) -> bool {
    stream.set_nonblocking(true).unwrap();
    let mut handle = stream;
    let mut byte = [0u8; 1];
    let open = match handle.read(&mut byte) {
        Ok(0) => false,
        Ok(_) => true,
        Err(error) => error.kind() == ErrorKind::WouldBlock,
    };
    stream.set_nonblocking(false).unwrap();
    open
}

/// Whether the client closes `stream` within the read timeout.
fn closes(stream: &UnixStream) -> bool {
    let mut handle = stream;
    let mut rest = Vec::new();
    handle.read_to_end(&mut rest).is_ok()
}

/// The server: refuses `identify` (informational for the client) and the
/// probe's `client-hello` (the probe stays, unverified), then checks the
/// probe when the long-lived connection sends its first request.
fn serve(listener: UnixListener) -> Seen {
    let mut probe = None;
    loop {
        let mut connection = accept(&listener);
        match connection.first["cmd"].as_str() {
            Some("identify") => refuse(&mut connection),
            Some("client-hello") => {
                refuse(&mut connection);
                probe = Some(connection);
            }
            _ => {
                let probe = probe.expect("no client-hello probe before the long-lived connection");
                let probe_open_at_first_request = open(&probe.stream);
                // Ends the long-lived connection: its request fails, and the
                // client's session ends.
                drop(connection);
                return Seen {
                    probe_open_at_first_request,
                    probe_closed_after: closes(&probe.stream),
                };
            }
        }
    }
}

mod owner_keepers {
    use super::*;

    #[test]
    fn the_app_probe_stays_open_until_the_long_lived_connection_is_answered() {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("dc-probe-{}-{}", std::process::id(), nanos));
        std::fs::create_dir_all(&dir).unwrap();
        let socket: PathBuf = dir.join("s.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (tx, rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let _ = tx.send(serve(listener));
        });

        let mut config = DaemonConfig::new("dc-probe");
        config.socket = Some(socket);
        config.install_key_file = Some(dir.join("frontend-install-key"));
        config.request_timeout = Duration::from_secs(2);
        config.min_backoff = Duration::from_secs(30);
        let mut client = DaemonClient::spawn(config, |_, _| {}).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        let seen = rx
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("the scripted server saw no long-lived connection");
        client.stop();
        server.join().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(
            seen,
            Seen { probe_open_at_first_request: true, probe_closed_after: true },
            "the probe must close only after the daemon answered the long-lived connection"
        );
    }
}
