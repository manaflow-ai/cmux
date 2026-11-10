//! A Chief subagent's workspace never closes by itself, short task or long,
//! running or finished: only the person closes it. A short-task close (a run
//! under 30 minutes whose report left nothing unlanded) closed workspaces
//! whose agent was still working (waiting on a build, a review or a reply),
//! and Chief went on driving an agent the sidebar no longer showed (Aziz
//! 2026-11-05: "why are your agents disappearing from sidebar?"). Only the
//! person's opt-in setting `subagents.closeFinishedWorkspaces` closes finished
//! ones.

mod common;

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::state::SubStatus;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_chief::workspaces::{self, Workspaces};
use serde_json::{Value, json};

#[derive(Default)]
struct Recorder {
    closed: Mutex<Vec<String>>,
}

impl Workspaces for Recorder {
    fn open(&self, key: &str, _s: &str, _n: &str, _g: &str, _c: &Path) -> Result<String, String> {
        Ok(key.to_owned())
    }
    fn rename(&self, _key: &str, _name: &str) -> Result<(), String> {
        Ok(())
    }
    fn close(&self, key: &str) -> Result<(), String> {
        self.closed.lock().unwrap().push(key.to_owned());
        Ok(())
    }
    fn close_idle(&self, key: &str) -> Result<bool, String> {
        self.closed.lock().unwrap().push(key.to_owned());
        Ok(true)
    }
    fn place(&self) -> String {
        "the test".into()
    }
    fn locate(&self, _key: &str) -> Option<workspaces::WorkspaceRef> {
        Some(workspaces::WorkspaceRef {
            id: "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e".into(),
            session: "main".into(),
        })
    }
}

/// A subagent's turn ends with the text after `REPORT:` in its task.
fn script() -> Script {
    let default = default_script();
    Box::new(move |turn, blocks: &[Value]| {
        let text = serde_json::to_string(blocks).unwrap_or_default();
        let Some(at) = text.find("REPORT:") else {
            return default(turn, blocks);
        };
        let report: String = text[at + 7..].chars().take_while(|c| *c != '|').collect();
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": report}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

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

/// a1 runs in its workspace and reports `report` after a run of `ran`.
/// What the recorder closed, and a1's recorded workspace after that.
fn finish_a1(report: &str, ran: Duration) -> (Vec<String>, Option<String>) {
    finish_a1_with(report, ran, false)
}

/// `finish_a1` with the person's close-on-finish setting on or off.
fn finish_a1_with(report: &str, ran: Duration, close: bool) -> (Vec<String>, Option<String>) {
    finish_a1_routed(report, ran, close, true, "")
}

/// `finish_a1` with every knob: `show` is `subagents.showWorkspaces`, and
/// `body` lines go before the report (they steer the lifetime route).
fn finish_a1_routed(
    report: &str,
    ran: Duration,
    close: bool,
    show: bool,
    body: &str,
) -> (Vec<String>, Option<String>) {
    let mut h = Harness::new(script());
    if close {
        h.brain
            .set_user_settings(Some(json!({"subagents": {"closeFinishedWorkspaces": true}})));
    }
    let recorder = Arc::new(Recorder::default());
    let ws: Arc<dyn Workspaces> = recorder.clone();
    h.brain.set_workspaces(Some(ws.clone()));
    // Shown at start (#26386: hidden unless this setting is on), unless the
    // test lets the lifetime route decide.
    if show {
        h.brain
            .set_setting("subagents.showWorkspaces", "true")
            .unwrap();
    }
    let sp = Arc::new(
        Spawner::new(
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
        )
        .with_workspaces(Some(ws))
        // Never the real user's cmux settings file.
        .with_user_settings(Some(h.dir.path().join("no-cmux-next.json"))),
    );
    h.connect();
    let task = format!("Title: Tab bar tweak\n{body}REPORT:{report}|");
    let worker = std::thread::spawn(move || sp.spawn(vec![task], None));
    let until = Instant::now() + Duration::from_secs(20);
    let mut idle_sent = false;
    let mut backdated = false;
    // Done, or its report is in (a report that did not land gets the host's
    // landing follow-up and runs on, which is when it must not close).
    let finished = |h: &Harness| {
        h.brain
            .state()
            .sub("a1")
            .is_some_and(|(_, s)| matches!(s.status, SubStatus::Done | SubStatus::Reported))
            || h.log()
                .iter()
                .any(|(_, t)| t.starts_with("[a1] Not landed"))
    };
    while !finished(&h) {
        assert!(Instant::now() < until, "a1 never finished: {:?}", h.log());
        if !backdated && h.brain.state().sub("a1").is_some_and(|(_, s)| s.run_ms > 0) {
            h.brain.backdate_sub_run("a1", ran);
            backdated = true;
        }
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
            continue;
        }
        if !idle_sent
            && worker.is_finished()
            && let Some(session) = sub_session(&h)
        {
            idle_sent = true;
            h.brain
                .step(Input::from(AgentEvent::SessionChanged(idle(&session))));
        }
    }
    assert!(backdated, "a1's run never started");
    // The close runs off the brain's thread.
    let until = Instant::now() + Duration::from_secs(2);
    while recorder.closed.lock().unwrap().is_empty() && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    // A close tells the brain its workspace is gone.
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(200)) {
        h.brain.step(input);
    }
    let workspace = h
        .brain
        .state()
        .sub("a1")
        .and_then(|(_, s)| s.workspace.clone());
    (recorder.closed.lock().unwrap().clone(), workspace)
}

#[test]
fn a_short_task_that_landed_keeps_its_workspace() {
    let (closed, workspace) = finish_a1("Done: renamed the button.", Duration::from_secs(5 * 60));
    assert!(closed.is_empty(), "a finished short task's workspace stays: {closed:?}");
    assert!(workspace.is_some(), "its workspace stays recorded");
}

#[test]
fn a_short_task_waiting_on_a_build_keeps_its_workspace() {
    // a38's report on 2026-11-05: still running, nothing said "not landed".
    let (closed, _) = finish_a1(
        "Release build passed; the fleet test runs are going and I will report when they finish.",
        Duration::from_secs(10 * 60),
    );
    assert!(closed.is_empty(), "a working agent's workspace stays: {closed:?}");
}

#[test]
fn a_long_task_keeps_its_workspace() {
    let (closed, _) = finish_a1("Done: rebuilt the sidebar.", Duration::from_secs(45 * 60));
    assert!(
        closed.is_empty(),
        "a long task's workspace stays: {closed:?}"
    );
}

#[test]
fn a_short_task_that_did_not_land_keeps_its_workspace() {
    let (closed, _) = finish_a1(
        "Not landed: the fix is unpushed, tests are red.",
        Duration::from_secs(5 * 60),
    );
    assert!(closed.is_empty(), "work still to do stays open: {closed:?}");
}

#[test]
fn the_persons_close_setting_still_closes_a_finished_workspace() {
    let (closed, workspace) = finish_a1_with(
        "Done: rebuilt the sidebar.",
        Duration::from_secs(45 * 60),
        true,
    );
    assert_eq!(closed.len(), 1, "subagents.closeFinishedWorkspaces closes it");
    assert_eq!(workspace, None, "and forgets its key");
}

/// The tucked reaper stays: a short task the route tucks into the collapsed
/// "Chief" group (something to watch, but short) closes when its work ends.
#[test]
fn a_tucked_workspace_still_closes_when_its_work_ends() {
    let (closed, workspace) = finish_a1_routed(
        "Done: renamed the button.",
        Duration::from_secs(5 * 60),
        false,
        false,
        "Open a terminal and run the tab bar check.\n",
    );
    assert_eq!(closed.len(), 1, "the tucked workspace closes");
    assert_eq!(workspace, None, "and its key is forgotten");
}

/// A shown short task (not tucked) keeps its workspace with the same report:
/// only the tucked reaper and the person's setting close one.
#[test]
fn a_shown_short_task_keeps_its_workspace_where_a_tucked_one_closes() {
    let (closed, workspace) = finish_a1_routed(
        "Done: renamed the button.",
        Duration::from_secs(5 * 60),
        false,
        false,
        "Sidebar: shown\nOpen a terminal and run the tab bar check.\n",
    );
    assert!(closed.is_empty(), "a shown workspace stays: {closed:?}");
    assert!(workspace.is_some());
}
