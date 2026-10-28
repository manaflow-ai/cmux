//! After work, the Chief shows it beside its chat (Lawrence 2026-10-20: "as a
//! default behavior for the Chief, when submissions are done, think about what
//! else would be useful to show in the workspace ... a column to the right to
//! show a browser preview or a diff"). A subagent's report that names landed
//! commits, pages or preview files reaches the Chief with a `<show>` block
//! that opens each in the right column; `show.afterReport` turns it off.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::show;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use serde_json::{Value, json};

const REPORT: &str = "Landed 1a2b3c4d5e6..9f8e7d6c5b4 on feat-cmux-next ([9f8e7d6](https://github.com/manaflow-ai/cmux/commit/9f8e7d6c5b4a)). Gallery: [index.html](file:///Users/me/fun/My%20Gallery/index.html), board at http://127.0.0.1:55999/.";

#[test]
fn a_landed_range_becomes_a_compare_page_in_the_right_column() {
    let block = show::block(REPORT).expect("the report names things to show");
    assert!(
        block.starts_with("<show>") && block.ends_with("</show>"),
        "{block}"
    );
    assert!(
        block.contains("cmux browser right navigate https://github.com/manaflow-ai/cmux/compare/1a2b3c4d5e6...9f8e7d6c5b4"),
        "{block}"
    );
    assert!(
        block.contains("cmux browser right navigate http://127.0.0.1:55999/"),
        "{block}"
    );
    // `right navigate` takes the URL as a word: `--url` is a usage error there (the
    // default Chief copied this hint 18 times from Oct 20 to 26; 17 got "cmux: usage").
    assert!(!block.contains("navigate --url"), "{block}");
    assert!(
        block.contains("--path '/Users/me/fun/My Gallery/index.html' --where tab"),
        "{block}"
    );
    // The commit link is covered by the diff line, not a page of its own.
    assert!(!block.contains("- page https://github.com"), "{block}");
    assert!(block.contains("never the dock"), "{block}");
}

#[test]
fn a_report_with_nothing_to_show_gets_no_block() {
    assert_eq!(
        show::block(
            "Not stuck: waiting on two Mac-mini runs (1234567 queued), see cmux://workspace/ws_1."
        ),
        None
    );
    assert_eq!(show::block("Nothing landed: tests are red."), None);
}

#[test]
fn a_range_without_a_github_link_reads_the_log_in_a_terminal() {
    let block = show::block("Pushed abcdef0..1234abc.").expect("a range");
    assert!(block.contains("git log -p abcdef0..1234abc"), "{block}");
}

#[test]
fn show_after_report_is_on_by_default_and_is_a_setting() {
    let mut h = Harness::new(default_script());
    let file = h.dir.path().join("settings.json");
    assert!(optchat_chief::chief_settings::ChiefSettings::load(&file).show_after_report);
    let answer = h
        .brain
        .set_setting("show.afterReport", "false")
        .expect("show.afterReport is a setting");
    assert_eq!(answer, "show.afterReport = false");
    assert!(h.brain.set_setting("show.afterReport", "maybe").is_err());
}

/// A subagent's turn ends with `REPORT`; the Chief's turns with the default answer.
fn report_script() -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        if !text.contains("SHOW-TASK") {
            return default(turn, blocks);
        }
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": REPORT}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

/// Spawns one subagent and steps the brain until its report is in the log.
fn delivered_report(h: &mut Harness) -> String {
    let spawner = Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ));
    h.connect();
    let worker = std::thread::spawn(move || spawner.spawn(vec!["SHOW-TASK land it".into()], None));
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    loop {
        if let Some((_, text)) = h.log().into_iter().find(|(_, t)| t.starts_with("[a1] ")) {
            worker.join().unwrap().expect("the spawn answers");
            return text;
        }
        assert!(Instant::now() < deadline, "no report: {:?}", h.log());
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        // The subagent's turn ran (its report is in its events): its
        // session goes idle, as acpmux reports it.
        if !idle_sent
            && worker.is_finished()
            && let Some(session) = sub_session(h)
        {
            idle_sent = true;
            h.brain
                .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
        }
    }
}

/// The subagent's session once its first prompt is in.
fn sub_session(h: &Harness) -> Option<String> {
    let inner = h.agents.inner.lock().unwrap();
    let k = inner
        .specs
        .iter()
        .position(|s| s.tags.contains_key("optchat.subagent"))?;
    let session = format!("s{}", k + 1);
    inner.prompt_sessions.contains(&session).then_some(session)
}

fn idle(session: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": session, "name": "a1", "status": "idle", "harness": "claude",
    }))
    .unwrap()
}

#[test]
fn a_finished_subagents_report_reaches_the_chief_with_what_to_show() {
    let mut h = Harness::new(report_script());
    let text = delivered_report(&mut h);
    assert!(text.contains("<show>"), "{text}");
    assert!(text.contains("compare/1a2b3c4d5e6...9f8e7d6c5b4"), "{text}");
}

#[test]
fn show_after_report_off_delivers_the_bare_report() {
    let mut h = Harness::new(report_script());
    h.brain
        .set_setting("show.afterReport", "false")
        .expect("a setting");
    let text = delivered_report(&mut h);
    assert!(text.contains("Landed 1a2b3c4d5e6"), "{text}");
    assert!(!text.contains("<show>"), "{text}");
}
