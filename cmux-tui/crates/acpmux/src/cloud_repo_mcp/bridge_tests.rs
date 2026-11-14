use super::*;
use std::os::unix::fs::PermissionsExt;

#[tokio::test]
async fn cloud_repo_cli_error_exit_preserves_recovery_and_literal_arguments() {
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("cmux");
    let argv = dir.path().join("argv");
    std::fs::write(&script, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nprintf '%s\\n' '{{\"code\":\"repo.needs_github\",\"message\":\"Connect GitHub.\",\"install_url\":\"https://github.com/install\"}}'\nexit 1\n", argv.display())).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let result = run_cli_with(
        script.as_os_str(),
        Some(std::ffi::OsStr::new("/tmp/daemon.sock")),
        REPO_ADD_ACTION,
        json!({"session":"chat-1","repo":"literal; $(false)","ref":"main"}),
    )
    .await
    .unwrap();
    assert_eq!(result["code"], "repo.needs_github");
    let words = std::fs::read_to_string(argv).unwrap();
    assert_eq!(
        words.lines().collect::<Vec<_>>(),
        vec![
            "--json",
            "--socket",
            "/tmp/daemon.sock",
            "cloud",
            "repo",
            "add",
            "--session",
            "chat-1",
            "--repo",
            "literal; $(false)",
            "--ref",
            "main"
        ]
    );
    assert_eq!(ok(result)["isError"], false);
    assert_eq!(
        ok(json!({"code":"seed.disk_full","message":"Free disk space and retry."}))["isError"],
        true
    );
}
