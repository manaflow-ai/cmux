//! Tests of `daemon.rs`: its state files and readiness line.
use super::*;

#[test]
fn a_refusal_on_the_readiness_line_is_the_error_text() {
    let line = r#"{"ready":false,"refused":"acpmux: this daemon's executable /tmp/a/acpmux is in a temporary folder"}"#;
    let err = not_ready(std::path::Path::new("/s"), line, &anyhow!("connect failed"));
    assert_eq!(
        err.to_string(),
        "acpmux: this daemon's executable /tmp/a/acpmux is in a temporary folder"
    );
    assert_eq!(super::exe_path::refused_line(r#"{"ready":false,"lockHeld":true}"#), None);
    assert!(
        not_ready(std::path::Path::new("/s"), "", &anyhow!("x"))
            .to_string()
            .contains("exited before")
    );
}

#[test]
fn daemon_log_refuses_a_symlink() {
    let dir = std::env::temp_dir().join(format!(
        "acpmux-log-link-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let target = dir.join("outside");
    let log = dir.join("daemon.log");
    std::fs::write(&target, "outside").unwrap();
    std::os::unix::fs::symlink(&target, &log).unwrap();

    assert!(open_daemon_log(&log).is_err(), "the daemon opened a linked log");
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "outside");
    let _ = std::fs::remove_dir_all(&dir);
}
