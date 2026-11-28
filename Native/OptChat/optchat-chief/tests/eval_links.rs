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

use optchat_chief::reply_links::{link_refs, link_refs_named};

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

const PR: &str = "https://github.com/manaflow-ai/cmux/pull/25572";
const SHA: &str = "184cb2f77473f0123456789abcdef0123456789a";

#[test]
fn a_named_workspace_id_shows_its_name() {
    let named = link_refs_named(
        &format!("a1 is in {WS}; {TAB} too."),
        Path::new("/Users/me"),
        &exists,
        &|id| (id == WS).then(|| "Chief [links] fix".to_owned()),
    );
    assert_eq!(
        named,
        format!(
            "a1 is in [Chief \\[links\\] fix](cmux://workspace/{WS}); [tab](cmux://tab/{TAB}) too."
        )
    );
}

#[test]
fn a_workspace_title_with_a_backslash_or_line_break_stays_one_link() {
    let named = link_refs_named(
        &format!("a1 is in {WS}."),
        Path::new("/Users/me"),
        &exists,
        &|id| (id == WS).then(|| "fix C:\\\nnext".to_owned()),
    );
    assert_eq!(
        named,
        format!("a1 is in [fix C:\\\\ next](cmux://workspace/{WS}).")
    );
}

#[test]
fn an_existing_link_with_nested_brackets_stays_whole() {
    let text = "[the [fix]](https://github.com/manaflow-ai/cmux/pull/25572)";
    assert_eq!(link(text), text);
}

#[test]
fn an_existing_link_with_escaped_brackets_stays_whole() {
    let text = r"[the \[fix\]](https://github.com/manaflow-ai/cmux/pull/25572)";
    assert_eq!(link(text), text);
}

#[test]
fn an_existing_link_with_code_or_a_quoted_target_stays_whole() {
    for text in [
        "[the `]` fix](https://github.com/manaflow-ai/cmux/pull/25572)",
        "[the ``[`]`` fix](https://github.com/manaflow-ai/cmux/pull/25572)",
        "[the 🔗 [fix]](https://github.com/manaflow-ai/cmux/pull/25572)",
        "[fix](https://github.com/manaflow-ai/cmux/pull/25572 \"a ) title\")",
        "[fix](<https://github.com/manaflow-ai/cmux/pull/25572?q=)>)",
    ] {
        assert_eq!(link(text), text);
    }
}

#[test]
fn preserving_an_existing_link_still_converts_the_next_bare_url() {
    let text = "[the [fix]](https://github.com/manaflow-ai/cmux/pull/25572) and https://github.com/manaflow-ai/cmux/pull/24680";
    assert_eq!(
        link(text),
        "[the [fix]](https://github.com/manaflow-ai/cmux/pull/25572) and [#24680](https://github.com/manaflow-ai/cmux/pull/24680)"
    );
}

#[test]
fn a_github_url_becomes_a_short_named_link() {
    assert_eq!(
        link(&format!("Opened {PR}.")),
        format!("Opened [#25572]({PR}).")
    );
    assert_eq!(
        link(
            "Landed https://github.com/manaflow-ai/cmux/commit/184cb2f77473f0123456789abcdef0123456789a, run https://github.com/manaflow-ai/cmux/actions/runs/39221907733 green"
        ),
        "Landed [184cb2f](https://github.com/manaflow-ai/cmux/commit/184cb2f77473f0123456789abcdef0123456789a), run [run 39221907733](https://github.com/manaflow-ai/cmux/actions/runs/39221907733) green"
    );
    assert_eq!(
        link("(see **https://github.com/manaflow-ai/cmux/issues/123#issuecomment-9**)"),
        "(see **[#123](https://github.com/manaflow-ai/cmux/issues/123#issuecomment-9)**)"
    );
}

#[test]
fn two_repositories_name_each_number_by_its_repository() {
    assert_eq!(
        link(
            "cmux https://github.com/manaflow-ai/cmux/pull/1 and hq https://github.com/manaflow-ai/cmuxterm-hq/pull/2"
        ),
        "cmux [cmux#1](https://github.com/manaflow-ai/cmux/pull/1) and hq [cmuxterm-hq#2](https://github.com/manaflow-ai/cmuxterm-hq/pull/2)"
    );
}

#[test]
fn an_owner_repo_number_links_to_that_repository() {
    assert_eq!(
        link("Fixed manaflow-ai/cmux#25572."),
        "Fixed [cmux#25572](https://github.com/manaflow-ai/cmux/issues/25572)."
    );
}

#[test]
fn a_bare_number_or_sha_links_only_with_one_repository_named() {
    // One repository in the reply: its numbers and shas are that repository's.
    assert_eq!(
        link(&format!("{PR} replaces #25560; head {SHA}.")),
        format!(
            "[#25572]({PR}) replaces [#25560](https://github.com/manaflow-ai/cmux/issues/25560); head [184cb2f](https://github.com/manaflow-ai/cmux/commit/{SHA})."
        )
    );
    // No repository: a bare number or sha could be the wrong repository's, so it stays.
    let text = "Fixed #25572 and landed 184cb2f77473f0123456789abcdef0123456789a.";
    assert_eq!(link(text), text);
    // Two repositories: the same.
    let linked = link("manaflow-ai/cmux#1 and manaflow-ai/cmuxterm-hq#2, then #3456");
    assert!(linked.ends_with(", then #3456"), "{linked}");
    // Short numbers, numbers in a word or code, and number-like words stay.
    let text = format!("{PR}: step #1, x#123, `#123`, #123abc");
    assert_eq!(
        link(&text),
        format!("[#25572]({PR}): step #1, x#123, `#123`, #123abc")
    );
}

/// Text with multibyte characters right before or after a reference scans by whole
/// characters: no panic, and the reference after a space still links.
#[test]
fn multibyte_text_beside_references_links_and_never_panics() {
    assert_eq!(
        link(&format!("Fix — {PR} é#123 …{WS} ✓ #25560")),
        format!(
            "Fix — [#25572]({PR}) é#123 …{WS} ✓ [#25560](https://github.com/manaflow-ai/cmux/issues/25560)"
        )
    );
    assert_eq!(
        link(&format!("“{WS}” — {TAB}")),
        format!("“{WS}” — [tab](cmux://tab/{TAB})")
    );
}

#[test]
fn a_github_link_already_written_and_other_github_pages_stay() {
    for text in [
        format!("[the fix]({PR})"),
        "https://github.com/manaflow-ai/cmux".to_owned(),
        "https://github.com/manaflow-ai/cmux/blob/main/README.md".to_owned(),
        "https://github.com/login/device".to_owned(),
    ] {
        assert_eq!(link(&text), text);
    }
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
