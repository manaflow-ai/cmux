/// A tool call's wait cap is that call's alone: neither the daemon a capped call starts nor
/// an agent or background task it runs keeps it (`TURN_SCOPED_ENV`), so a background
/// `cmux-gh wait --timeout 2400` waits its 2400 s and not the starter's 150.
#[test]
fn a_tool_calls_wait_cap_is_caller_scoped() {
    for key in ["GLAEDA_WAIT_CACHE_WARM_S", "TASK_WAIT_MAX_S", "TASK_WAIT_DEADLINE"] {
        assert!(super::is_caller_scoped_key(key), "{key} is one call's");
    }
    // The switch a person sets on purpose (GLAEDA_WAIT_CACHE_WARM=0) is not a call's cap.
    assert!(!super::is_caller_scoped_key("GLAEDA_WAIT_CACHE_WARM"));
}
