use super::*;
use std::path::Path;

fn argv(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

/// A bundle folder with a `codex` script that prints `version`, and a
/// manifest pinning `pinned_sha` (None: the script's real hash).
fn bundle(dir: &Path, version: &str, pinned_sha: Option<&str>, protocol: u32) -> PathBuf {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let program = bin.join("codex");
    std::fs::write(&program, format!("#!/bin/sh\necho 'codex-cli {version}'\n")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let sha = pinned_sha.map(str::to_owned).unwrap_or_else(|| sha256_file(&program).unwrap());
    let manifest =
        Manifest { version: version.into(), path: "bin/codex".into(), sha256: sha, protocol };
    std::fs::write(dir.join(MANIFEST), serde_json::to_vec(&manifest).unwrap()).unwrap();
    program
}

#[test]
fn off_changes_nothing_and_says_nothing() {
    let dir = tempfile::tempdir().unwrap();
    bundle(dir.path(), "0.150.0", None, 2);
    let r = resolve(false, Some(dir.path()), &argv(&["codex", "app-server"]));
    assert_eq!(r, Resolution::Off);
    assert_eq!(r.health(), None);
}

#[test]
fn a_missing_bundle_falls_back_to_the_installed_cli() {
    let dir = tempfile::tempdir().unwrap();
    let r = resolve(true, Some(dir.path()), &argv(&["codex", "app-server"]));
    let health = r.health().unwrap();
    assert_eq!(health.source, Source::Installed);
    assert_eq!(health.fallback.as_deref(), Some("no bundle installed"));
}

#[cfg(unix)]
#[test]
fn a_hash_mismatch_falls_back_to_the_installed_cli() {
    let dir = tempfile::tempdir().unwrap();
    bundle(dir.path(), "0.150.0", Some(&"0".repeat(64)), 2);
    let health = resolve(true, Some(dir.path()), &argv(&["codex", "app-server"])).health().unwrap();
    assert_eq!(health.source, Source::Installed);
    assert_eq!(health.bundled_version.as_deref(), Some("0.150.0"));
    assert!(health.fallback.unwrap().contains("sha256"));
}

#[cfg(unix)]
#[test]
fn a_whole_bundle_runs_in_place_of_codex() {
    let dir = tempfile::tempdir().unwrap();
    let program = bundle(dir.path(), "0.150.0", None, 2);
    let launch = argv(&["codex", "-c", "k=v", "app-server"]);
    let r = resolve(true, Some(dir.path()), &launch);
    let Resolution::Bundled { program: got, .. } = &r else { panic!("{r:?}") };
    assert_eq!(got, &program);
    assert_eq!(r.health().unwrap().source, Source::Bundled);
    let (cmd, args) = command_line(got, &launch);
    assert_eq!(cmd, program.to_string_lossy());
    assert_eq!(args, argv(&["-c", "k=v", "app-server"]));
    // A second resolve reuses the passed check.
    assert_eq!(resolve(true, Some(dir.path()), &launch), r);
}

#[cfg(unix)]
#[test]
fn a_version_the_manifest_does_not_name_falls_back() {
    let dir = tempfile::tempdir().unwrap();
    let program = bundle(dir.path(), "0.150.0", None, 2);
    std::fs::write(&program, "#!/bin/sh\necho 'codex-cli 0.149.0'\n").unwrap();
    let sha = sha256_file(&program).unwrap();
    let manifest =
        Manifest { version: "0.150.0".into(), path: "bin/codex".into(), sha256: sha, protocol: 2 };
    std::fs::write(dir.path().join(MANIFEST), serde_json::to_vec(&manifest).unwrap()).unwrap();
    let health = resolve(true, Some(dir.path()), &argv(&["codex", "app-server"])).health().unwrap();
    assert_eq!(health.source, Source::Installed);
    assert!(health.fallback.unwrap().contains("0.149.0"));
}

#[test]
fn an_incompatible_protocol_falls_back() {
    let dir = tempfile::tempdir().unwrap();
    bundle(dir.path(), "0.150.0", None, 99);
    let health = resolve(true, Some(dir.path()), &argv(&["codex", "app-server"])).health().unwrap();
    assert_eq!(health.source, Source::Installed);
    assert_eq!(health.protocol, Some(99));
}

#[test]
fn a_profile_with_its_own_server_is_never_taken_over() {
    let dir = tempfile::tempdir().unwrap();
    bundle(dir.path(), "0.150.0", None, 2);
    for launch in [
        argv(&["/opt/bin/codex", "app-server"]),
        argv(&["cmux-codex", "app-server"]),
        argv(&["codex", "app-server", "--listen", "ws://127.0.0.1:9000"]),
        argv(&["codex", "app-server", "--listen=unix:///tmp/s"]),
    ] {
        let health = resolve(true, Some(dir.path()), &launch).health().unwrap();
        assert_eq!(health.source, Source::Installed, "{launch:?}");
    }
}

#[test]
fn a_manifest_path_cannot_leave_its_folder() {
    let dir = tempfile::tempdir().unwrap();
    let manifest = Manifest {
        version: "1".into(),
        path: "../codex".into(),
        sha256: "0".repeat(64),
        protocol: 2,
    };
    std::fs::write(dir.path().join(MANIFEST), serde_json::to_vec(&manifest).unwrap()).unwrap();
    let health = resolve(true, Some(dir.path()), &argv(&["codex", "app-server"])).health().unwrap();
    assert_eq!(health.fallback.as_deref(), Some("bundle path leaves its folder"));
}

/// The bench: resolving a launch against a 64 MiB bundle (about a Codex
/// binary's size), cold (hash + `--version`) and then warm (a `stat`).
/// `cargo test -p acpmux --release codex_bundle::tests::bench -- --ignored --nocapture`
#[cfg(unix)]
#[test]
#[ignore = "bench"]
fn bench_resolve_cold_and_warm() {
    let dir = tempfile::tempdir().unwrap();
    let program = bundle(dir.path(), "0.150.0", None, 2);
    let mut body = std::fs::read(&program).unwrap();
    body.extend(std::iter::repeat_n(b'#', 64 << 20));
    std::fs::write(&program, &body).unwrap();
    let sha = sha256_file(&program).unwrap();
    let manifest =
        Manifest { version: "0.150.0".into(), path: "bin/codex".into(), sha256: sha, protocol: 2 };
    std::fs::write(dir.path().join(MANIFEST), serde_json::to_vec(&manifest).unwrap()).unwrap();
    let launch = argv(&["codex", "app-server"]);
    let start = std::time::Instant::now();
    assert!(matches!(resolve(true, Some(dir.path()), &launch), Resolution::Bundled { .. }));
    let cold = start.elapsed();
    let rounds = 1000;
    let start = std::time::Instant::now();
    for _ in 0..rounds {
        assert!(matches!(resolve(true, Some(dir.path()), &launch), Resolution::Bundled { .. }));
    }
    let warm = start.elapsed() / rounds;
    println!("codex_bundle bench: 64 MiB bundle cold {cold:?}, warm {warm:?} per resolve");
}
