use super::*;

/// A daemon a command starts is handed its home and socket absolute
/// (`daemon/login_placement.rs` `daemon_env`): from relative ones, the command must derive
/// the same socket, short alias included, or it waits on one the daemon never binds.
#[test]
fn a_long_relative_home_or_socket_uses_the_same_socket_alias() {
    let cwd = Path::new("/work/a-folder-long-enough-that-its-socket-needs-a-short-alias");
    let long = "x".repeat(80);
    let alias = |configured: Option<&str>, home: &Path, cwd: &Path| {
        let (configured, home) = socket_inputs(configured, home, Some(cwd));
        cmux_agent_pane_policy::environment::socket_path(configured.as_deref(), &home, 501)
    };
    let elsewhere = Path::new("/elsewhere");
    assert_eq!(alias(None, Path::new(&long), cwd), alias(None, &cwd.join(&long), elsewhere));
    let sock = format!("{long}/a.sock");
    let abs_sock = cwd.join(&sock).to_string_lossy().into_owned();
    assert_eq!(
        alias(Some(&sock), Path::new("/h"), cwd),
        alias(Some(&abs_sock), Path::new("/h"), elsewhere)
    );
}
