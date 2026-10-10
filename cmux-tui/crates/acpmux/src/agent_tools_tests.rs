#[test]
fn a_spawned_agent_never_inherits_a_helper_token() {
    let mut cmd = tokio::process::Command::new("/bin/true");
    crate::cua_socket::scrub_agent_env(&mut cmd);
    let removed: Vec<String> = cmd
        .as_std()
        .get_envs()
        .filter(|(_, v)| v.is_none())
        .map(|(k, _)| k.to_string_lossy().into_owned())
        .collect();
    for key in [
        "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN",
        "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN",
        "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN",
        "CMUX_CUA_SOCKET_AUTH_TOKEN",
    ] {
        assert!(removed.iter().any(|k| k == key), "{key} must be removed from an agent's env");
    }
}
