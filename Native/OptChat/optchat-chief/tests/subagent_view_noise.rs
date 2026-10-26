//! A subagent's view leaves out the recent one-message lines that only say
//! the Chief stopped its turn (the log keeps them until the fold drops them
//! for new turns): they told a subagent nothing and were about one line in
//! eight of a recent view's tail.

use optchat_chief::prompt::subagent_blocks;

#[test]
fn stop_lines_leave_the_subagents_view_and_the_rest_stays() {
    let view = "<chat>\n\
                0+2048|user: old summary\n\
                11470+1|tool: mcp__optchat__send {\"text\":\"hi\"}\n\
                11471+1|echo: outcome: done. sent in the thread of message 11461\n\
                11474+1|tool: mcp__optchat__stop null\n\
                11475+1|echo: outcome: done. the turn ends now; nothing more is posted\n\
                11476+1|user: next ask\n\
                </chat>";
    let text: String = subagent_blocks(view, "Do it.")
        .iter()
        .filter_map(|b| b["text"].as_str().map(str::to_owned))
        .collect();
    assert!(!text.contains("optchat__stop"), "{text}");
    assert!(!text.contains("the turn ends now"), "{text}");
    for kept in [
        "0+2048|user: old summary",
        "11470+1|tool: mcp__optchat__send",
        "11476+1|user: next ask",
        "Do it.",
    ] {
        assert!(text.contains(kept), "{kept} missing: {text}");
    }
}
