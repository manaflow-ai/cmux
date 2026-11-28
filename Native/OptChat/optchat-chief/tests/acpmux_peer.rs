//! The Chief speaks to its acpmux socket only when the process that serves
//! it is the acpmux it runs (cx-ggai). The real `optchat-chief` binary
//! (`chief agents list`, the same connect as the host's acpmux link) against
//! a separate server process on the socket: a server whose executable is
//! `ACPMUX_BIN` gets the request and answers; a same-user squatter whose
//! executable is not `ACPMUX_BIN` is refused before the first byte.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

mod real_python;

/// A newline JSON-RPC server on `socket` that answers `initialize` and
/// `_acpmux/sessions` and appends every byte it reads to `received`.
const SERVER: &str = r#"
import json, os, socket, sys
path, received = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(8)
open(received, "ab").close()
while True:
    conn, _ = s.accept()
    buf = b""
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            break
        with open(received, "ab") as f:
            f.write(chunk)
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                req = json.loads(line)
            except ValueError:
                continue
            result = {"sessions": []} if req.get("method") == "_acpmux/sessions" else {}
            conn.sendall((json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": result}) + "\n").encode())
    conn.close()
"#;

struct Server {
    child: Child,
    received: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The interpreter that runs the server: its own process image.
fn python() -> PathBuf {
    real_python::image()
}

fn serve(dir: &Path, socket: &Path) -> Server {
    let script = dir.join("server.py");
    std::fs::write(&script, SERVER).unwrap();
    let received = dir.join("received");
    let child = Command::new(python())
        .arg("-I")
        .arg(&script)
        .arg(socket)
        .arg(&received)
        .stdin(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while std::os::unix::net::UnixStream::connect(socket).is_err() {
        assert!(Instant::now() < deadline, "the server never listened");
        std::thread::sleep(Duration::from_millis(50));
    }
    Server { child, received }
}

/// `optchat-chief agents list` against `socket`, with `ACPMUX_BIN=acpmux_bin`.
fn list(dir: &Path, socket: &Path, acpmux_bin: &Path) -> (bool, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args(["agents", "list"])
        .env("ACPMUX_SOCKET", socket)
        .env("ACPMUX_BIN", acpmux_bin)
        .env("MUX_HOME", dir.join("home"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr),
    )
}

fn received(server: &Server) -> Vec<u8> {
    let mut bytes = Vec::new();
    if let Ok(mut f) = std::fs::File::open(&server.received) {
        f.read_to_end(&mut bytes).unwrap();
    }
    bytes
}

#[test]
fn the_acpmux_the_chief_runs_gets_its_requests() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let server = serve(dir.path(), &socket);
    let (ok, output) = list(dir.path(), &socket, &python());
    assert!(ok, "the Chief connects to the acpmux it runs: {output}");
    assert!(
        String::from_utf8_lossy(&received(&server)).contains("\"initialize\""),
        "the server got the Chief's requests"
    );
}

#[test]
fn a_same_user_squatter_on_the_socket_is_refused_before_any_byte() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let squatter = serve(dir.path(), &socket);
    // The Chief runs another acpmux than the process that holds its socket.
    let acpmux_bin = std::fs::canonicalize("/bin/sh").unwrap();
    let (ok, output) = list(dir.path(), &socket, &acpmux_bin);
    std::thread::sleep(Duration::from_millis(300)); // test harness: let a written byte reach the file
    let got = received(&squatter);
    assert!(
        got.is_empty(),
        "the squatter got nothing from the Chief, got {:?}",
        String::from_utf8_lossy(&got)
    );
    assert!(!ok, "the Chief refuses the socket: {output}");
    assert!(
        output.contains("refused the acpmux socket peer"),
        "the refusal names the peer: {output}"
    );
}
