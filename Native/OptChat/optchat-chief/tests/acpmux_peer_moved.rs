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
use std::time::{Duration, Instant, SystemTime};

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

/// `year`-01-01T00:00:00Z.
fn jan_1(year: i32) -> SystemTime {
    chrono::NaiveDate::from_ymd_opt(year, 1, 1)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc()
        .into()
}

/// The header of the BER element at `b[at..]`: its tag, header length and
/// content length (None: indefinite, ended by an end-of-contents 00 00).
fn ber_header(b: &[u8], at: usize) -> (u8, usize, Option<usize>) {
    let first = b[at + 1] as usize;
    if first < 0x80 {
        return (b[at], 2, Some(first));
    }
    let n = first & 0x7f;
    if n == 0 {
        return (b[at], 2, None);
    }
    let len = b[at + 2..at + 2 + n]
        .iter()
        .fold(0usize, |len, &byte| (len << 8) | byte as usize);
    (b[at], 2 + n, Some(len))
}

/// Where the BER element at `at` ends.
fn ber_end(b: &[u8], at: usize) -> usize {
    match ber_header(b, at) {
        (_, header, Some(len)) => at + header + len,
        (_, header, None) => {
            let mut child = at + header;
            while b[child..child + 2] != [0, 0] {
                child = ber_end(b, child);
            }
            child + 2
        }
    }
}

/// The offsets of the children of the constructed BER element at `at`.
fn ber_children(b: &[u8], at: usize) -> Vec<usize> {
    let (_, header, len) = ber_header(b, at);
    let end = len.map(|len| at + header + len);
    let mut children = Vec::new();
    let mut child = at + header;
    while end.map_or(b[child..child + 2] != [0, 0], |end| child < end) {
        children.push(child);
        child = ber_end(b, child);
    }
    children
}

/// A DER definite-length header for `tag` and `len` content bytes.
fn der_header(tag: u8, len: usize) -> Vec<u8> {
    if len < 0x80 {
        return vec![tag, len as u8];
    }
    let bytes: Vec<u8> = len
        .to_be_bytes()
        .into_iter()
        .skip_while(|&b| b == 0)
        .collect();
    [vec![tag, 0x80 | bytes.len() as u8], bytes].concat()
}

/// The CMS signature (slot 0x10000) of a SuperBlob, and its blob's offset.
fn cms_of(blob: &[u8]) -> (usize, Vec<u8>) {
    let be = |at: usize| u32::from_be_bytes(blob[at..at + 4].try_into().unwrap()) as usize;
    for i in 0..be(8) {
        let (slot, offset) = (be(12 + 8 * i), be(16 + 8 * i));
        if slot == 0x10000 {
            return (offset, blob[offset + 8..offset + be(offset + 4)].to_vec());
        }
    }
    panic!("no CMS slot");
}

/// `blob` (a SuperBlob) with its CMS blob's content replaced by `cms`,
/// every blob laid out again.
fn with_cms(blob: &[u8], cms: &[u8]) -> Vec<u8> {
    let be = |at: usize| u32::from_be_bytes(blob[at..at + 4].try_into().unwrap()) as usize;
    let count = be(8);
    let mut index = Vec::new();
    let mut body = Vec::new();
    let start = 12 + 8 * count;
    for i in 0..count {
        let (slot, offset) = (be(12 + 8 * i), be(16 + 8 * i));
        let bytes = if slot == 0x10000 {
            let mut b = 0xfade_0b01u32.to_be_bytes().to_vec();
            b.extend(((cms.len() + 8) as u32).to_be_bytes());
            b.extend_from_slice(cms);
            b
        } else {
            blob[offset..offset + be(offset + 4)].to_vec()
        };
        index.push((slot as u32, (start + body.len()) as u32));
        body.extend(bytes);
    }
    let mut out = blob[0..4].to_vec();
    out.extend(((start + body.len()) as u32).to_be_bytes());
    out.extend((count as u32).to_be_bytes());
    for (slot, offset) in index {
        out.extend(slot.to_be_bytes());
        out.extend(offset.to_be_bytes());
    }
    out.extend(body);
    out
}

/// The offsets of a CMS signature's signerInfos SET, of its single
/// SignerInfo and of that signer's unsignedAttrs ([1]).
fn signer_and_unsigned(cms: &[u8]) -> (usize, usize, usize) {
    // ContentInfo { contentType, [0] { SignedData { ..., signerInfos } } }
    let signed_data = ber_children(cms, ber_children(cms, 0)[1])[0];
    let signer_infos = *ber_children(cms, signed_data).last().unwrap();
    assert_eq!(cms[signer_infos], 0x31, "signerInfos is a SET");
    let signers = ber_children(cms, signer_infos);
    assert_eq!(signers.len(), 1);
    let unsigned = *ber_children(cms, signers[0]).last().unwrap();
    assert_eq!(cms[unsigned], 0xa1, "the signer has unsignedAttrs");
    (signer_infos, signers[0], unsigned)
}

/// The nightly signature without its RFC 3161 timestamp: the same signer
/// signature (unsignedAttrs are outside what it signs), so it verifies, but
/// only its signer's unauthenticated signingTime claim says when.
fn nightly_without_timestamp() -> KernelSignature {
    let mut signature = nightly();
    let (_, cms) = cms_of(&signature.blob);
    let (set, signer, unsigned) = signer_and_unsigned(&cms);
    let (_, signer_header, _) = ber_header(&cms, signer);
    let fields = &cms[signer + signer_header..unsigned];
    let signer_der = [der_header(0x30, fields.len()), fields.to_vec()].concat();
    let stripped = [
        &cms[..set],
        &der_header(0x31, signer_der.len()),
        &signer_der,
        &cms[ber_end(&cms, set)..],
    ]
    .concat();
    signature.blob = with_cms(&signature.blob, &stripped);
    signature
}

// The nightly fixture: leaf "Developer ID Application: Manaflow, Inc."
// valid 2026-04-15..2031-04-16, signed and timestamped 2026-10-21.

// Also true of the code before the time seam (CMSDecoder used the verified
// timestamp first): a guard against a rule stricter than Apple's.
#[test]
fn moved_peer_a_timestamped_signature_stays_valid_after_its_certificate_expires() {
    assert_eq!(
        code_signature::verify_at(&nightly(), &ours(), jan_1(2032)),
        Ok(())
    );
}

#[test]
fn moved_peer_a_signature_without_a_secure_timestamp_is_refused_after_its_certificate_expires() {
    let bare = nightly_without_timestamp();
    // Inside the certificate's validity it verifies: only the time differs.
    assert_eq!(
        code_signature::verify_at(&bare, &ours(), jan_1(2027)),
        Ok(())
    );
    let err = code_signature::verify_at(&bare, &ours(), jan_1(2032)).unwrap_err();
    assert!(err.contains("no secure timestamp"), "{err}");
    // Before the certificate was issued, the same.
    let err = code_signature::verify_at(&bare, &ours(), jan_1(2025)).unwrap_err();
    assert!(err.contains("no secure timestamp"), "{err}");
}

#[test]
fn moved_peer_a_broken_timestamp_token_does_not_extend_validity() {
    let mut forged = nightly();
    let (offset, mut cms) = cms_of(&forged.blob);
    let (_, _, unsigned) = signer_and_unsigned(&cms);
    // The unsignedAttrs have a definite length, and their last byte is the
    // last byte of the timestamp token's own RSA signature.
    assert!(ber_header(&cms, unsigned).2.is_some());
    let last = ber_end(&cms, unsigned) - 1;
    cms[last] ^= 0xff;
    forged.blob[offset + 8..offset + 8 + cms.len()].copy_from_slice(&cms);
    // Refused after the leaf's expiry: by the CMS verification of the token,
    // or, if a broken token only lost its time, at the chain.
    let err = code_signature::verify_at(&forged, &ours(), jan_1(2032)).unwrap_err();
    assert!(
        err.contains("CMS signature does not verify") || err.contains("no secure timestamp"),
        "{err}"
    );
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
    // OU, and with no secure timestamp. While that leaf is valid, the CMS
    // chain to Apple Root CA verifies and the OU rule refuses; once it has
    // expired, the chain is refused at the current time (the fleet's Xcode:
    // "Software Signing", valid to 2026-10-24). Either way it is the
    // signature rule that refuses, never a pass.
    let apple = Signer {
        team: "59GAB85EFG".into(),
        identifier: "com.apple.clang".into(),
    };
    let signature_rule = |err: &str| {
        err.contains("signing certificate's team (OU)") || err.contains("no secure timestamp")
    };
    let err = code_signature::verify(&running, &apple).unwrap_err();
    assert!(signature_rule(&err), "{err}");

    // The whole peer check reaches the signature rules instead of stopping at
    // the unknown executable, and still refuses this peer.
    let err = optchat_chief::acpmux_peer::check(&stream, Some(&clang)).unwrap_err();
    assert!(signature_rule(&err), "{err}");
}
