//! An acpmux whose executable an app update moved away and deleted (cx-ggai,
//! 2026-10-23: a NIGHTLY update left the default Chief home's acpmux running
//! from a deleted bundle, and every new Chief brain refused it with "pid
//! 43389's executable is unknown"). Such a peer passes only when the kernel's
//! code signature of the running process is Apple-anchored and has our
//! acpmux's team ID and identifier; anything else is still refused.
//!
//! `fixtures/nightly-acpmux-signature.bin` is that daemon's signature as the
//! kernel gave it (`CS_OPS_BLOB` through the socket's audit token), with its
//! `CS_OPS_STATUS` flags and cdhash below: a real Developer ID signature of
//! `cmux` by team 7WLXT3NR37.
#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use optchat_chief::code_signature::{self, KernelSignature, Signer};

const FLAGS: u32 = 0x2201_0301;
const CDHASH: &str = "2bdd93ce63ab41c473de54776d0ef5001d3b0a0e";

fn hex(s: &str) -> [u8; 20] {
    let mut out = [0u8; 20];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap();
    }
    out
}

fn nightly() -> KernelSignature {
    KernelSignature {
        flags: FLAGS,
        cdhash: hex(CDHASH),
        blob: std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/nightly-acpmux-signature.bin"),
        )
        .unwrap(),
    }
}

fn ours() -> Signer {
    Signer {
        team: "7WLXT3NR37".into(),
        identifier: "cmux".into(),
    }
}

#[test]
fn moved_peer_a_moved_acpmux_signed_by_our_team_as_our_acpmux_passes() {
    assert_eq!(code_signature::verify(&nightly(), &ours()), Ok(()));
}

#[test]
fn moved_peer_another_team_or_identifier_is_refused() {
    let other_team = Signer {
        team: "59GAB85EFG".into(),
        ..ours()
    };
    let err = code_signature::verify(&nightly(), &other_team).unwrap_err();
    assert!(err.contains("team"), "{err}");
    let other_identifier = Signer {
        identifier: "acpmux-other".into(),
        ..ours()
    };
    let err = code_signature::verify(&nightly(), &other_identifier).unwrap_err();
    assert!(err.contains("signed as"), "{err}");
}

#[test]
fn moved_peer_ad_hoc_or_invalid_code_is_refused() {
    let mut adhoc = nightly();
    adhoc.flags |= 0x2;
    assert!(code_signature::verify(&adhoc, &ours()).is_err());
    let mut invalid = nightly();
    invalid.flags &= !0x1;
    assert!(code_signature::verify(&invalid, &ours()).is_err());
}

#[test]
fn moved_peer_a_blob_that_is_not_the_code_the_kernel_runs_is_refused() {
    let mut other = nightly();
    other.cdhash[0] ^= 1;
    let err = code_signature::verify(&other, &ours()).unwrap_err();
    assert!(err.contains("cdhash"), "{err}");
}

#[test]
fn moved_peer_a_rewritten_code_directory_fails_its_cms_signature() {
    use sha2::Digest as _;
    let mut forged = nightly();
    // The CodeDirectory is slot 0 (offset at 16); change one code page hash
    // near its end and give the kernel's cdhash of the forged directory.
    let b = &forged.blob;
    let at = u32::from_be_bytes([b[16], b[17], b[18], b[19]]) as usize;
    let len = u32::from_be_bytes([b[at + 4], b[at + 5], b[at + 6], b[at + 7]]) as usize;
    forged.blob[at + len - 1] ^= 0xff;
    let hash = sha2::Sha256::digest(&forged.blob[at..at + len]);
    forged.cdhash.copy_from_slice(&hash[..20]);
    let err = code_signature::verify(&forged, &ours()).unwrap_err();
    assert!(err.contains("CMS"), "{err}");
}

#[test]
fn moved_peer_our_acpmux_on_disk_must_be_apple_anchored() {
    let clang = xcode_clang();
    assert_eq!(
        code_signature::of_file(&clang),
        Ok(Signer {
            team: "59GAB85EFG".into(),
            identifier: "com.apple.clang".into()
        })
    );
    // The test binary is signed ad hoc by the linker.
    let me = std::env::current_exe().unwrap();
    assert!(code_signature::of_file(&me).is_err());
}

/// Xcode's clang: signed with a team ID (Apple's), and it waits on stdin.
fn xcode_clang() -> PathBuf {
    let out = Command::new("xcrun")
        .args(["-f", "clang"])
        .output()
        .unwrap();
    assert!(out.status.success(), "xcrun -f clang");
    std::fs::canonicalize(String::from_utf8(out.stdout).unwrap().trim()).unwrap()
}

/// A server whose executable is gone: Python listens on `socket`, then
/// execs a copy of `binary` (same pid, the socket kept), and the copy is
/// deleted, as an update deletes the bundle a running acpmux came from.
struct Gone(Child);

impl Drop for Gone {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

const LISTEN_THEN_EXEC: &str = r#"
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1]); s.listen(8); s.set_inheritable(True)
os.execv(sys.argv[2], sys.argv[2:])
"#;

fn gone_server(dir: &Path, socket: &Path, binary: &Path) -> Gone {
    let copy = dir.join("moved-acpmux");
    std::fs::copy(binary, &copy).unwrap();
    let child = Command::new("python3")
        .args(["-I", "-c", LISTEN_THEN_EXEC])
        .arg(socket)
        .arg(&copy)
        .args(["-fsyntax-only", "-x", "c", "-"])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while std::os::unix::net::UnixStream::connect(socket).is_err() {
        assert!(Instant::now() < deadline, "the server never listened");
        std::thread::sleep(Duration::from_millis(50)); // test harness: wait for the fixture's listen
    }
    std::thread::sleep(Duration::from_millis(500)); // test harness: let the exec finish
    std::fs::remove_file(&copy).unwrap();
    Gone(child)
}

#[test]
fn moved_peer_the_kernel_signature_of_a_peer_whose_executable_is_gone_is_read_and_checked() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("acpmux.sock");
    let clang = xcode_clang();
    let _server = gone_server(dir.path(), &socket, &clang);
    let stream = std::os::unix::net::UnixStream::connect(&socket).unwrap();

    let running = code_signature::running_peer(&stream).unwrap();
    assert_eq!(running.flags & 0x3, 0x1, "valid and not ad hoc");
    // Apple signs clang with its own leaf (OU "Apple Software"), not a team
    // OU: the CMS chain to Apple Root CA verifies, and the OU rule refuses.
    let apple = Signer {
        team: "59GAB85EFG".into(),
        identifier: "com.apple.clang".into(),
    };
    let err = code_signature::verify(&running, &apple).unwrap_err();
    assert!(err.contains("signing certificate's team (OU)"), "{err}");

    // The whole peer check reaches the signature rule instead of stopping at
    // the unknown executable, and still refuses this peer.
    let err = optchat_chief::acpmux_peer::check(&stream, Some(&clang)).unwrap_err();
    assert!(err.contains("signing certificate's team (OU)"), "{err}");
}
