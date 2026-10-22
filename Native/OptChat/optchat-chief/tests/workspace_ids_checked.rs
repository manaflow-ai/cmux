//! `workspaces::missing_workspace_ids`: a Chief reply that names a workspace id the user's
//! session does not have is caught (Lawrence 2026-10-22: the reply named ws_09ac7482…, which the
//! user's session did not have).

use std::collections::HashSet;

use optchat_chief::workspaces::{missing_workspace_ids, missing_workspaces_warning};

const MINE: &str = "ws_aa239423f26740e81c8b0dc94c758142";
const GONE: &str = "ws_09ac748271314676609875b7ede9adef";

fn known() -> HashSet<String> {
    [MINE, "ws_932af9536b354c15222aa5c6834f78a0"]
        .into_iter()
        .map(str::to_owned)
        .collect()
}

#[test]
fn a_workspace_id_the_session_lacks_is_reported_once() {
    let text = format!(
        "a453 runs in [TUI send](cmux://workspace/{GONE}); also `{GONE}`, and a467 in cmux://workspace/{MINE}."
    );
    assert_eq!(
        missing_workspace_ids(&text, &known()),
        vec![GONE.to_owned()]
    );
}

#[test]
fn known_ids_keys_and_longer_tokens_are_not_reported() {
    let text = format!(
        "{MINE} and cmux://workspace/f8d01127-5c4a-45d5-8568-50a56041a6b6, xws_{0}, {GONE}0, ws_123",
        "0".repeat(32)
    );
    assert!(missing_workspace_ids(&text, &known()).is_empty());
}

#[test]
fn the_warning_names_the_ids_and_the_lookup() {
    let warning = missing_workspaces_warning(&[GONE.to_owned()]);
    assert!(warning.contains(GONE));
    assert!(warning.contains("cmux --json workspace list"));
}
