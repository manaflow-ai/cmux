//! #32989: a Chief prompted from one window opened its subagents' workspaces in
//! another. The app places a run's new workspace in its caller's window, and a
//! Chief turn's caller is the Home chat (the window the person prompted it
//! from), so the subagent workspace's `action.run` names that caller.

use std::path::Path;

use optchat_chief::workspaces::{OPEN_ACTION, open_request, open_request_for};
use serde_json::json;

#[test]
fn a_subagent_workspace_is_opened_from_the_chiefs_home_chat() {
    let request = open_request("s1", "Fix the build", "ws-key", Path::new("/tmp/repo"));
    assert_eq!(request["method"], "action.run");
    assert_eq!(request["params"]["action"], OPEN_ACTION);
    assert_eq!(request["params"]["caller"], json!({"home_chat": true}));
    assert_eq!(
        request["params"]["origin"], "script",
        "a script's run: it never takes focus"
    );
}

#[test]
fn a_named_chiefs_subagent_names_the_same_caller() {
    let request = open_request_for(
        Path::new("/tmp/chief-home"),
        "s1",
        "Fix",
        "ws-key",
        Path::new("/tmp/repo"),
    );
    assert_eq!(request["params"]["caller"], json!({"home_chat": true}));
}
