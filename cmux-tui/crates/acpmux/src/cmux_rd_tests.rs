use super::*;
use std::sync::Mutex;

/// A network and `enable` that never leave the test: the archive it serves, the calls made.
#[derive(Default)]
struct Fake {
    archive: Vec<u8>,
    enable_fails: Mutex<bool>,
    fetched: Mutex<Vec<String>>,
    enabled: Mutex<Vec<(PathBuf, PathBuf)>>,
}

impl Fake {
    fn serving(archive: Vec<u8>) -> Fake {
        Fake { archive, ..Fake::default() }
    }
    fn fetches(&self) -> usize {
        self.fetched.lock().unwrap().len()
    }
    fn enables(&self) -> usize {
        self.enabled.lock().unwrap().len()
    }
}

impl Host for Fake {
    async fn fetch(&self, url: &str) -> Result<Vec<u8>> {
        self.fetched.lock().unwrap().push(url.to_owned());
        Ok(self.archive.clone())
    }
    async fn enable(&self, bin: &Path, home: &Path) -> Result<()> {
        self.enabled.lock().unwrap().push((bin.to_owned(), home.to_owned()));
        if *self.enable_fails.lock().unwrap() {
            bail!("enable refused");
        }
        Ok(())
    }
}

/// A `.tar.gz` holding `binary` at `path`.
fn archive(path: &str, binary: &[u8]) -> Vec<u8> {
    let mut tar =
        tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
    let mut header = tar::Header::new_gnu();
    header.set_size(binary.len() as u64);
    header.set_mode(0o755);
    header.set_cksum();
    tar.append_data(&mut header, path, binary).unwrap();
    tar.into_inner().unwrap().finish().unwrap()
}

/// A pin for `archive` (leaked: a [`Pin`] holds `'static` strings, as the real one does).
fn pin_for(version: &'static str, archive: &[u8]) -> Pin {
    Pin {
        version,
        url: "https://example.invalid/cmux-rd.tar.gz",
        sha256: Box::leak(crate::sha256::sha256_hex(archive).into_boxed_str()),
    }
}

fn place(dir: &Path) -> Place {
    Place {
        os: "linux",
        arch: ARCH,
        join: Join::Joined,
        home: dir.join("acpmux"),
        bin: dir.join("user/.local/bin/cmux-rd"),
    }
}

fn run<T>(future: impl Future<Output = T>) -> T {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(future)
}

#[test]
fn the_pin_is_the_x86_64_linux_release_with_a_sha256() {
    assert!(PIN.url.ends_with(&format!("cmux-rd-{}-x86_64-unknown-linux-gnu.tar.gz", PIN.version)));
    assert!(PIN.url.contains(&format!("/releases/download/cmux-rd-v{}/", PIN.version)));
    assert_eq!(PIN.sha256.len(), 64);
    assert!(PIN.sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
}

#[test]
fn a_wrong_sha256_is_refused_and_nothing_is_installed() {
    let dir = tempfile::tempdir().unwrap();
    let place = place(dir.path());
    std::fs::create_dir_all(&place.home).unwrap();
    let fake = Fake::serving(archive("bin/cmux-rd", b"#!/bin/sh\n"));
    let wrong = Pin { sha256: PIN.sha256, ..pin_for("0.2.7", b"other bytes") };
    let error = run(ensure(&place, &wrong, &fake)).unwrap_err();
    assert!(format!("{error:#}").contains("sha256 mismatch"), "{error:#}");
    assert_eq!(fake.fetches(), 1);
    assert_eq!(fake.enables(), 0, "a refused archive is never enabled");
    assert!(!place.bin.exists(), "nothing is installed");
    assert!(!place.bin.parent().unwrap().exists(), "not even its folder");
    assert_eq!(record(&place.home), None);
}

#[test]
fn the_pinned_archive_installs_and_enables_once_per_version() {
    let dir = tempfile::tempdir().unwrap();
    let place = place(dir.path());
    std::fs::create_dir_all(&place.home).unwrap();
    let first = archive("bin/cmux-rd", b"cmux-rd one");
    let pin = pin_for("0.2.7", &first);
    let fake = Fake::serving(first);
    assert_eq!(
        run(ensure(&place, &pin, &fake)).unwrap(),
        Outcome::Ready { installed: true, enabled: true }
    );
    assert_eq!(std::fs::read(&place.bin).unwrap(), b"cmux-rd one");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&place.bin).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o755);
    }
    assert_eq!(*fake.enabled.lock().unwrap(), vec![(place.bin.clone(), place.home.clone())]);
    let written = record(&place.home).unwrap();
    assert_eq!(written.version, "0.2.7");
    assert_eq!(written.archive_sha256, pin.sha256);
    assert_eq!(written.binary_sha256, crate::sha256::sha256_hex(b"cmux-rd one"));
    assert_eq!(written.enabled_sha256.as_deref(), Some(pin.sha256));
    let leftovers: Vec<_> = std::fs::read_dir(place.bin.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(leftovers, vec![std::ffi::OsString::from("cmux-rd")], "no staged file is left");

    // The next start: nothing fetched, `enable` not run again.
    assert_eq!(
        run(ensure(&place, &pin, &fake)).unwrap(),
        Outcome::Ready { installed: false, enabled: false }
    );
    assert_eq!((fake.fetches(), fake.enables()), (1, 1));

    // A new pinned version: installed and enabled once more.
    let second = archive("cmux-rd-0.2.8/bin/cmux-rd", b"cmux-rd two");
    let next = pin_for("0.2.8", &second);
    let fake = Fake::serving(second);
    assert_eq!(
        run(ensure(&place, &next, &fake)).unwrap(),
        Outcome::Ready { installed: true, enabled: true }
    );
    assert_eq!(std::fs::read(&place.bin).unwrap(), b"cmux-rd two");
    assert_eq!(record(&place.home).unwrap().enabled_sha256.as_deref(), Some(next.sha256));
}

#[test]
fn a_failed_enable_runs_again_at_the_next_start_with_no_new_download() {
    let dir = tempfile::tempdir().unwrap();
    let place = place(dir.path());
    std::fs::create_dir_all(&place.home).unwrap();
    let bytes = archive("bin/cmux-rd", b"cmux-rd");
    let pin = pin_for("0.2.7", &bytes);
    let fake = Fake::serving(bytes);
    *fake.enable_fails.lock().unwrap() = true;
    assert!(run(ensure(&place, &pin, &fake)).is_err());
    assert_eq!(record(&place.home).unwrap().enabled_sha256, None, "no marker for a failure");
    *fake.enable_fails.lock().unwrap() = false;
    assert_eq!(
        run(ensure(&place, &pin, &fake)).unwrap(),
        Outcome::Ready { installed: false, enabled: true }
    );
    assert_eq!((fake.fetches(), fake.enables()), (1, 2));
}

#[test]
fn a_changed_binary_is_put_back() {
    let dir = tempfile::tempdir().unwrap();
    let place = place(dir.path());
    std::fs::create_dir_all(&place.home).unwrap();
    let bytes = archive("bin/cmux-rd", b"cmux-rd");
    let pin = pin_for("0.2.7", &bytes);
    let fake = Fake::serving(bytes);
    run(ensure(&place, &pin, &fake)).unwrap();
    std::fs::write(&place.bin, b"something else").unwrap();
    assert_eq!(
        run(ensure(&place, &pin, &fake)).unwrap(),
        Outcome::Ready { installed: true, enabled: false },
        "the same version: enabled already"
    );
    assert_eq!(std::fs::read(&place.bin).unwrap(), b"cmux-rd");
}

#[test]
fn not_joined_copied_not_linux_and_other_architectures_are_skipped_untouched() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = archive("bin/cmux-rd", b"cmux-rd");
    let pin = pin_for("0.2.7", &bytes);
    let cases = [
        (Place { join: Join::NotJoined, ..place(dir.path()) }, Outcome::NotJoined),
        (Place { join: Join::Copied, ..place(dir.path()) }, Outcome::Copied),
        (Place { os: "macos", ..place(dir.path()) }, Outcome::NotLinux),
        (Place { arch: "aarch64", ..place(dir.path()) }, Outcome::NoBuild),
    ];
    for (place, expected) in cases {
        let fake = Fake::serving(bytes.clone());
        assert_eq!(run(ensure(&place, &pin, &fake)).unwrap(), expected);
        assert_eq!((fake.fetches(), fake.enables()), (0, 0), "{expected:?}");
        assert!(!place.bin.exists() && !place.home.join(RECORD).exists(), "{expected:?}");
    }
}

#[test]
fn an_archive_without_bin_cmux_rd_is_refused() {
    assert!(member(&archive("cmux-rd", b"x")).is_err());
    assert!(member(&archive("bin/cmux-rd-helper", b"x")).is_err());
    assert_eq!(member(&archive("./bin/cmux-rd", b"x")).unwrap(), b"x");
}

#[test]
fn a_join_to_a_loopback_hub_is_not_one_to_install_for() {
    assert!(loopback("http://127.0.0.1:4100"));
    assert!(loopback("http://localhost:8787"));
    assert!(loopback("http://[::1]:8787"));
    assert!(!loopback("https://cmux.com"));
}

#[cfg(unix)]
#[test]
fn the_join_state_reads_the_home() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("acpmux");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(join_state(&home), Join::NotJoined, "no record");
    let write = |origin: &str, revoked: bool| {
        let path = home.join("machine-credential.json");
        let record = serde_json::json!({"credential":"cmm_test","machine_id":"machine_test",
            "team_id":"team_test","name":"test","hub_origin":origin,"last_heartbeat":null,
            "revoked":revoked,"wgPublicKey":"key"});
        std::fs::write(&path, record.to_string()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    };
    write("https://cmux.example", false);
    assert_eq!(join_state(&home), Join::Joined);
    write("https://cmux.example", true);
    assert_eq!(join_state(&home), Join::NotJoined, "revoked");
    write("http://127.0.0.1:4100", false);
    assert_eq!(join_state(&home), Join::NotJoined, "a test hub");
}
