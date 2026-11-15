use super::*;

fn os(args: &[&str]) -> Vec<OsString> {
    args.iter().map(OsString::from).collect()
}

#[test]
fn a_stdio_mcp_server_runs_on_a_small_runtime() {
    for name in [
        "acpmux-mcp",
        "subsession-mcp",
        "forum-mcp",
        "offer-mcp",
        "secret-mcp",
        "cua-mcp",
        "repo-mcp",
        "hosted-mcp",
        "github-mcp",
    ] {
        assert_eq!(runtime_workers(&os(&[name])), Some(MCP_WORKERS), "{name}");
        assert_eq!(runtime_workers(&os(&["--json", name])), Some(MCP_WORKERS), "{name}");
    }
    let bridge = os(&["bridge", "mcp", "--as", "codex-desktop"]);
    assert_eq!(runtime_workers(&bridge), Some(MCP_WORKERS));
    // acpmux's own servers in one process per chat: one worker.
    assert_eq!(runtime_workers(&os(&["tools-mcp"])), Some(TOOLS_MCP_WORKERS));
    assert_eq!(runtime(&os(&["tools-mcp"])).unwrap().metrics().num_workers(), 1);
}

#[test]
fn every_other_command_keeps_the_default_runtime() {
    for args in [
        &["ls"][..],
        &["daemon", "run"],
        &["send", "forum-mcp"],
        &[],
        &["--json"],
        &["bridge", "inbox"],
    ] {
        assert_eq!(runtime_workers(&os(args)), None, "{args:?}");
    }
}

#[test]
fn the_small_runtime_has_its_workers_and_not_one_per_core() {
    let small = runtime(&os(&["forum-mcp"])).unwrap();
    assert_eq!(small.metrics().num_workers(), MCP_WORKERS);
    // Every other command keeps tokio's default: one worker per core.
    let default = runtime(&os(&["ls"])).unwrap();
    if std::thread::available_parallelism().unwrap().get() > MCP_WORKERS {
        assert!(default.metrics().num_workers() > MCP_WORKERS);
    }
}
