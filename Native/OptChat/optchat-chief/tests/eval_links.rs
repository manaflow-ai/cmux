//! Chief fast eval, group `links` (deterministic, no model call): every Chief reply links what it
//! names, never a raw id or path (Lawrence, 2026-10-26: "reply with links to stuff properly";
//! the user's profile: "never write a raw URL, id, sha or path"). The model is told the rule; the
//! host's last pass (`reply_links::link_refs`, after `workspaces::link_subagents`) links what it
//! still wrote bare, so Home and iOS show a link whatever the model did:
//! - a cmux object id (`ws_…`, `tab_…`, `pane_…`) becomes its `cmux://` link;
//! - a path that exists on the Chief's machine (`/Users/…`, `~/…`, bare or alone in a code
//!   span) becomes a `file://` link named by its last part.
//!
//! Code fences, code spans with anything but one path, existing links and URLs stay as written.

use std::path::Path;

use optchat_chief::reply_links::link_refs;

const WS: &str = "ws_4190e34695946139e454022d54b3bcf7";
const TAB: &str = "tab_8167aba764916990ee8959f617ea3d9d";
const PANE: &str = "pane_0f51c0de0f51c0de0f51c0de0f51c0de";

fn exists(p: &Path) -> bool {
    matches!(
        p.to_str(),
        Some(
            "/Users/me/fun/cmux-prompt-commits.md"
                | "/Users/me/fun/cmux"
                | "/Users/me/fun/cmux/src/main.rs"
                | "/Users/me/a b/x.md"
        )
    )
}

fn link(text: &str) -> String {
    link_refs(text, Path::new("/Users/me"), &exists)
}

#[test]
fn a_bare_cmux_id_becomes_its_link() {
    assert_eq!(
        link(&format!("Opened {WS} and {TAB}.")),
        format!("Opened [workspace](cmux://workspace/{WS}) and [tab](cmux://tab/{TAB}).")
    );
    assert_eq!(
        link(&format!("- **{PANE}**: the right column")),
        format!("- **[pane](cmux://pane/{PANE})**: the right column")
    );
}

#[test]
fn an_id_in_code_a_link_or_a_longer_word_stays() {
    for text in [
        format!("`cmux workspace {WS} move --index 0`"),
        format!("[GitHub runner limit ticket](cmux://workspace/{WS})"),
        format!("cmux://workspace/{WS}"),
        format!("x{WS}"),
        format!("{WS}x"),
        "ws_short and tab_".to_owned(),
        format!("```\n{TAB}\n```"),
    ] {
        assert_eq!(link(&text), text);
    }
}

#[test]
fn a_mac_path_that_exists_becomes_a_file_link() {
    assert_eq!(
        link("Wrote /Users/me/fun/cmux-prompt-commits.md."),
        "Wrote [cmux-prompt-commits.md](file:///Users/me/fun/cmux-prompt-commits.md)."
    );
    assert_eq!(
        link("Repo: ~/fun/cmux, branch feat-cmux-next"),
        "Repo: [cmux](file:///Users/me/fun/cmux), branch feat-cmux-next"
    );
    assert_eq!(
        link("see `~/fun/cmux/src/main.rs`"),
        "see [main.rs](file:///Users/me/fun/cmux/src/main.rs)"
    );
    assert_eq!(
        link("at /Users/me/fun/cmux/src/main.rs:42 now"),
        "at [main.rs:42](file:///Users/me/fun/cmux/src/main.rs) now"
    );
}

#[test]
fn a_path_that_does_not_exist_code_with_more_than_a_path_and_urls_stay() {
    for text in [
        "Wrote /Users/me/nothing-here.md",
        "`cd ~/fun/cmux && git status`",
        "https://example.com/Users/me/fun/cmux",
        "[the repo](file:///Users/me/fun/cmux)",
        "[~/fun/cmux](file:///Users/me/fun/cmux)",
        "src/main.rs and fun/cmux",
        "```\n~/fun/cmux\n```",
    ] {
        assert_eq!(link(text), text);
    }
}

#[test]
fn a_file_url_is_escaped() {
    assert_eq!(
        link("`/Users/me/a b/x.md`"),
        "[x.md](file:///Users/me/a%20b/x.md)"
    );
}

#[test]
fn text_with_nothing_to_link_is_unchanged() {
    let text = "- a671: GitHub runner limit ticket, filed.\n- **Needs you**: nothing.";
    assert_eq!(link(text), text);
}

mod common;

/// The posted reply goes through the pass: a turn that writes a bare workspace id and a bare path
/// of a file that exists posts both as links (the path on a Mac host only).
#[test]
fn the_posted_reply_links_a_bare_workspace_id_and_path() {
    use serde_json::json;
    let file = tempfile::NamedTempFile::new().unwrap();
    let path = file.path().to_str().unwrap().to_owned();
    let said = format!("Opened {WS}; notes in {path}.");
    let script: common::Script = Box::new(move |_, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            common::update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": said}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    });
    let mut h = common::Harness::new(script);
    h.connect();
    h.say("user_local", "where is it?");
    h.settle();
    let sends = h.owner.lock().unwrap().sends();
    let reply = &sends.last().expect("a reply").1;
    assert!(
        reply.contains(&format!("[workspace](cmux://workspace/{WS})")),
        "{reply}"
    );
    // A Chief host on a cloud VM (Linux) links no paths: they are not this Mac's files.
    assert_eq!(
        reply.contains("](file://"),
        cfg!(target_os = "macos"),
        "{reply}"
    );
}
