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

/// The managed-unit tests write a fake `systemctl` and then run it. Run at once, one test's
/// fork could inherit the other's still-open write of its script, and the exec then fails with
/// ETXTBSY ("Text file busy"): one at a time.
#[cfg(target_os = "linux")]
static FAKE_SYSTEMCTL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[cfg(target_os = "linux")]
#[tokio::test]
async fn managed_unit_start_avoids_a_symlinked_default_home() {
    use std::os::unix::fs::PermissionsExt;
    let _one_at_a_time = FAKE_SYSTEMCTL.lock().await;

    let dir = std::env::temp_dir().join(format!(
        "acpmux-managed-start-{}-{}",
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    let supervised = dir.join("supervised");
    std::fs::create_dir_all(&supervised).unwrap();
    let link = dir.join(".acpmux");
    std::os::unix::fs::symlink(&supervised, &link).unwrap();
    let socket = link.join("acpmux.sock");

    // The safety invariant stays in force; the managed path must not call it
    // for the CLI's symlinked default home.
    assert!(crate::config::private_state_dir(&link).is_err());

    let systemctl = dir.join("systemctl");
    std::fs::write(
        &systemctl,
        format!(
            "#!/bin/sh\nif [ \"$2\" = show ] && [ \"$5\" = LoadState ]; then echo loaded; exit 0; fi\nif [ \"$2\" = show ] && [ \"$5\" = Environment ]; then echo ACPMUX_HOME={}; exit 0; fi\nif [ \"$2\" = start ]; then : > \"$(dirname \"$0\")/started\"; exit 0; fi\nexit 1\n",
            supervised.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let started = dir.join("started");
    let detached = dir.join("detached");
    connect_with_systemctl(&systemctl, &link, &socket, true, {
        let started = started.clone();
        let detached = detached.clone();
        move || {
            let started = started.clone();
            let detached = detached.clone();
            async move {
                assert!(!detached.exists(), "the CLI spawned a detached daemon");
                if started.exists() {
                    Ok(())
                } else {
                    Err(anyhow!("the managed unit has not started"))
                }
            }
        }
    })
    .await
    .unwrap();

    assert!(started.exists(), "the CLI did not start the managed unit");
    assert!(!socket.exists(), "the test should not need a detached socket");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn managed_unit_start_matches_shortened_sockets() {
    use std::os::unix::fs::PermissionsExt;
    let _one_at_a_time = FAKE_SYSTEMCTL.lock().await;
    let scratch = cmux_unix_socket::short_test_dir("managed-socket");
    let dir = scratch.path();
    std::fs::create_dir_all(dir).unwrap();
    let unit_home = dir.join("long-home-".repeat(15));
    std::fs::create_dir_all(&unit_home).unwrap();
    for configured in [None, Some(unit_home.join("configured.sock"))] {
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        let socket = std::path::PathBuf::from(cmux_agent_pane_policy::environment::socket_path(
            configured.as_deref().and_then(|p| p.to_str()),
            &unit_home,
            uid,
        ));
        assert!(socket.as_os_str().len() < 104, "socket was not shortened");
        let environment = format!(
            "ACPMUX_HOME={} {}",
            unit_home.display(),
            configured
                .as_ref()
                .map(|p| format!("ACPMUX_SOCKET={}", p.display()))
                .unwrap_or_default()
        );
        let systemctl = dir.join("systemctl");
        std::fs::write(&systemctl, format!(
            "#!/bin/sh\ncase \"$5\" in LoadState) echo loaded;; Environment) echo '{environment}';; esac\n"
        )).unwrap();
        std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o700)).unwrap();
        let result =
            managed_unit_connect_with(&systemctl, &unit_home, &socket, &|| async { Ok(()) })
                .await
                .unwrap();
        assert_eq!(result, Some(()), "managed daemon rejected its short socket");
    }
}
