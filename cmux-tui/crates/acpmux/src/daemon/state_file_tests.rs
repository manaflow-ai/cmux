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

/// The managed-unit tests write a fake `systemctl` and then run it. Any test in this binary
/// that forks while this process holds a write descriptor to the script hands it to its child
/// until that child execs, and the exec then fails with ETXTBSY ("Text file busy"); a lock
/// over these tests alone left every other forking test in the window. The script is written
/// by [`crate::test_exec::write_executable`], in its own process, so no fork here inherits it.

#[cfg(target_os = "linux")]
#[tokio::test]
async fn managed_unit_start_avoids_a_symlinked_default_home() {
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
    crate::test_exec::write_executable(
        &systemctl,
        format!(
            "#!/bin/sh\nif [ \"$2\" = show ] && [ \"$5\" = LoadState ]; then echo loaded; exit 0; fi\nif [ \"$2\" = show ] && [ \"$5\" = Environment ]; then echo ACPMUX_HOME={}; exit 0; fi\nif [ \"$2\" = start ]; then : > \"$(dirname \"$0\")/started\"; exit 0; fi\nexit 1\n",
            supervised.display()
        ),
    );
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
        crate::test_exec::write_executable(
            &systemctl,
            format!(
                "#!/bin/sh\ncase \"$5\" in LoadState) echo loaded;; Environment) echo '{environment}';; esac\n"
            ),
        );
        let result =
            managed_unit_connect_with(&systemctl, &unit_home, &socket, &|| async { Ok(()) })
                .await
                .unwrap();
        assert_eq!(result, Some(()), "managed daemon rejected its short socket");
    }
}

/// A fake `systemctl` for `acpmux.service` in `home` whose `ActiveState` is `state`; each
/// `ActiveState` probe adds a line to `probes` beside it.
#[cfg(target_os = "linux")]
fn fake_unit_in_state(
    dir: &std::path::Path,
    home: &std::path::Path,
    state: &str,
) -> std::path::PathBuf {
    let systemctl = dir.join("systemctl");
    crate::test_exec::write_executable(
        &systemctl,
        format!(
            "#!/bin/sh\ncase \"$5\" in\n  LoadState) echo loaded; exit 0;;\n  Environment) echo ACPMUX_HOME={}; exit 0;;\n  ActiveState) echo x >> \"$(dirname \"$0\")/probes\"; echo {state}; exit 0;;\nesac\n[ \"$2\" = start ] && exit 0\nexit 1\n",
            home.display()
        ),
    );
    systemctl
}

/// A fleet lane host, 11-06: a review box ran `acpmux` while `acpmux.service` was stopping for
/// a restart. A unit still `deactivating` keeps the command waiting for the unit's next daemon:
/// a detached one would run in the review box's scope, under its task and CPU limits.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn managed_unit_still_stopping_keeps_the_wait() {
    let scratch = cmux_unix_socket::short_test_dir("managed-stopping");
    let dir = scratch.path();
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let socket = crate::config::socket_path_for(&home, None);
    let systemctl = fake_unit_in_state(dir, &home, "deactivating");
    let probes = dir.join("probes");
    let served = managed_unit_connect_with(&systemctl, &home, &socket, &|| {
        let probes = probes.clone();
        async move {
            let seen = std::fs::read_to_string(&probes).unwrap_or_default().lines().count();
            if seen >= 3 { Ok(seen) } else { Err(anyhow!("the unit's next daemon is not up")) }
        }
    })
    .await
    .unwrap();
    assert_eq!(served, Some(3), "a stopping unit sent the command to a detached daemon");
}

/// A unit systemd marked inactive or failed has no daemon coming: the command takes the
/// detached path.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn managed_unit_gone_takes_the_detached_path() {
    for state in ["inactive", "failed"] {
        let scratch = cmux_unix_socket::short_test_dir("managed-gone");
        let dir = scratch.path();
        let home = dir.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let socket = crate::config::socket_path_for(&home, None);
        let systemctl = fake_unit_in_state(dir, &home, state);
        let result = managed_unit_connect_with(&systemctl, &home, &socket, &|| async {
            Err::<(), _>(anyhow!("no daemon"))
        })
        .await
        .unwrap();
        assert_eq!(result, None, "a {state} unit kept the wait");
    }
}
