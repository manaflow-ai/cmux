//! Chief fast eval, group assistant (a676, Lawrence 2026-10-26: Chief should
//! feel like Instinct/Muse: it remembers the person's preferences, answers
//! short, acts instead of asking, follows every open task until done). The
//! parts of that a test can hold without a model: the tool exists for the
//! Chief and not for subagents, the CLI form works for harnesses without
//! MCP, and the system prompt carries the rules. The model's own behavior is
//! graded by the JSON cases evals/cases/assistant-*.json.

use optchat_chief::tools::{Call, Command, command};

const PREF: &str = "Reply in one short bullet list, one line per agent.";

#[test]
fn remember_is_a_chief_tool() {
    let call = Call::parse("remember", &serde_json::json!({"text": PREF}));
    assert!(call.is_ok(), "{:?}", call.err());
    let list = optchat_chief::mcp::tools_for(false).to_string();
    assert!(
        list.contains("\"remember\""),
        "the Chief's MCP list has remember"
    );
}

#[test]
fn subagents_have_no_remember() {
    let list = optchat_chief::mcp::tools_for(true).to_string();
    assert!(
        !list.contains("\"remember\""),
        "a subagent never writes the profile"
    );
}

#[test]
fn remember_works_from_the_cli_launcher() {
    match command("remember", &["Never", "ask", "before", "safe", "reads."]) {
        Ok(Command::Call(_)) => {}
        Ok(_) => panic!("remember TEXT is a call"),
        Err(e) => panic!("{e}"),
    }
}

#[test]
fn a_secret_is_never_remembered() {
    let r = Call::parse(
        "remember",
        &serde_json::json!({"text": "token ghp_abcdefghijklmnopqrstuvwxyz0123"}),
    );
    assert!(r.is_err());
}

#[test]
fn the_prompt_says_to_remember_preferences() {
    let p = optchat_chief::prompt::claude_md(None);
    assert!(p.contains("remember(text)"), "names the tool");
    assert!(p.contains("lasting preference"), "says when");
}

#[test]
fn the_prompt_says_to_follow_through_and_report_unasked() {
    let p = optchat_chief::prompt::claude_md(None);
    assert!(p.contains("stays yours until it is"), "owns open tasks");
    assert!(p.contains("not landed"), "names open states");
    assert!(p.contains("without being asked"), "reports unasked");
}

#[test]
fn the_prompt_says_to_decide_instead_of_asking() {
    let p = optchat_chief::prompt::claude_md(None);
    assert!(p.contains("Default picked"), "names the default it picked");
    assert!(
        p.contains("only before money, legal, destructive"),
        "asks only for money, legal, destructive or sign-in steps"
    );
}

#[test]
fn the_prompt_keeps_status_replies_to_one_line_per_task() {
    let p = optchat_chief::prompt::claude_md(None);
    assert!(p.contains("one line per task or agent"), "status shape");
    assert!(p.contains("No intro line, no closing line"), "no filler");
    assert!(
        p.contains("Never narrate your own steps"),
        "no tool narration"
    );
}
