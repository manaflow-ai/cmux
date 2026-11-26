#[test]
fn the_router_starts_under_the_daemon_prefix() {
    let [standalone, tui] = crate::self_command::test_commands();
    let fifo = std::path::Path::new("/tmp/owner.fifo");
    let args = |c: &std::process::Command| -> Vec<String> {
        c.get_args().map(|a| a.to_string_lossy().into_owned()).collect()
    };
    assert_eq!(args(&super::router_command(&standalone, fifo)), ["router", "serve"]);
    let command = super::router_command(&tui, fifo);
    assert_eq!(command.get_program(), tui.exe.as_os_str());
    assert_eq!(args(&command), ["acp", "router", "serve"]);
}
