//! The daemon's launchd agent (`com.acpmux.daemon`) runs at the
//! process-roles table's `ProcessType` (threading-model.md "Process
//! roles"), on a fresh `host setup` and after a `host update` of a host an
//! older acpmux set up.

use super::*;

fn process_type_entry() -> String {
    format!("<key>ProcessType</key><string>{}</string>", LaunchdJob::AcpmuxDaemon.process_type())
}

#[test]
fn the_daemon_agent_runs_at_the_process_roles_table_value() {
    let plist = launchd_plist("/Users/ana");
    assert!(plist.contains(&process_type_entry()), "{plist}");
    assert!(plist.contains("<key>ProcessType</key><string>Interactive</string>"), "{plist}");
    assert!(!plist.contains("__"), "every placeholder is filled: {plist}");
    assert!(plist.contains("<string>/Users/ana/.local/bin/acpmux</string>"), "{plist}");
}

#[test]
fn a_reload_sets_the_table_value_before_launchd_reads_the_plist() {
    let set = format!(
        "plutil -replace ProcessType -string {} ~/Library/LaunchAgents/com.acpmux.daemon.plist",
        LaunchdJob::AcpmuxDaemon.process_type()
    );
    let at = LAUNCHD_RELOAD.find(&set).expect("the reload sets ProcessType");
    let bootstrap = LAUNCHD_RELOAD.find("launchctl bootstrap").unwrap();
    assert!(at < bootstrap, "{LAUNCHD_RELOAD}");
    assert!(LAUNCHD_RELOAD.find("launchctl bootout").unwrap() < at, "{LAUNCHD_RELOAD}");
}
