//! Subagent workspace names and sidebar groups (Lawrence 2026-10-19: "when
//! you make a new workspace you do name it better. And you need to group it
//! better as well", then "I don't like the checkmark"). A workspace is
//! `aN · Short title`, sits in a topic group, and its name never changes
//! when the subagent finishes.

mod common;

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::state::SubStatus;
use optchat_chief::subagents::{Spawner, SubagentSettings};
use optchat_chief::tools::Orchestrator;
use optchat_chief::workspaces::{self, AGENTS_GROUP_NAME, Workspaces};

/// Real spawn tasks of 2026-10-19 and the titles they must give.
#[test]
fn titles_drop_the_user_preamble_and_stay_short() {
    let cases = [
        (
            "User (u2455), cmux-next sidebar workspace groups. Work in a new worktree `sidebar-group-drag` off origin/feat-cmux-next.",
            "Sidebar workspace groups",
        ),
        (
            "ACP missing user prompt User: \"When I start a session the prompt is gone\"",
            "ACP missing user prompt",
        ),
        (
            "Title: Sidebar group drag\nUser (u2455), cmux-next sidebar workspace groups.",
            "Sidebar group drag",
        ),
        (
            "Landing audit: feat-cmux-next\nThe user said: check what landed.",
            "Landing audit",
        ),
        (
            "cmux-next (repo ~/fun/cmux, branch feat-cmux-next). User (u2392): \"omnibar for popover web windows need to reuse the same omnibar code.\"",
            "Omnibar for popover web windows…",
        ),
        (
            "User asked (msg 1500): \"read chromium source code, see how they style hibernated tabs.\"",
            "Read chromium source code, see…",
        ),
    ];
    for (task, want) in cases {
        assert_eq!(workspaces::title(task), want, "task: {task}");
        assert_eq!(workspaces::name("a7", task), format!("a7 · {want}"));
    }
}

#[test]
fn no_title_starts_with_user_has_a_check_mark_or_runs_long() {
    let tasks = [
        "User (u2469): \"when you make a new workspace you do name it better\"",
        "User (verbatim): \"The check for updates thing needs better animations for both coming in and coming out.\"",
        "The user (Lawrence) said about cmux-next (NIGHTLY): \"bottom left has this weird thing i dont like\"",
        "User",
        "",
        "✓ a12 · done already",
        "Follow-up to a103 (sr2 for everyone; plans/sr2-everyone/REPORT.md). User said: don't wait on me.",
    ];
    for task in tasks {
        let t = workspaces::title(task);
        assert!(!t.is_empty(), "{task:?}");
        assert!(!t.to_lowercase().starts_with("user"), "{task:?} -> {t:?}");
        assert!(!t.contains('✓'), "{task:?} -> {t:?}");
        assert!(t.chars().count() <= 32, "{task:?} -> {t:?}");
    }
}

#[test]
fn tasks_go_into_topic_groups() {
    let cases = [
        (
            "Title: Sidebar group drag\nfix the color bar",
            "Sidebar & tabs",
        ),
        ("Title: Omnibar Chrome parity\n...", "Browser & parity"),
        ("Title: Home New Message page\n...", "Home & chat"),
        ("Title: Landing audit\n...", "Nightly & CI"),
        ("Title: macOS matrix fuzz\n...", "Crashes & QA"),
        ("Title: Mermaid parser\n...", "Markdown & editor"),
        ("Title: Centered pane divider\n...", "Panes & layout"),
        ("Title: Chief default Claude\n...", "Agents & routing"),
        ("Title: Idle power + wakeups\n...", "Performance"),
        (
            "Title: Domains\nGroup: Accounts & billing\n...",
            "Accounts & billing",
        ),
        ("Title: Something odd\nnothing to match", AGENTS_GROUP_NAME),
    ];
    for (task, want) in cases {
        assert_eq!(workspaces::topic_group(task), want, "task: {task}");
    }
}

/// Records what the brain and spawner do to workspaces.
#[derive(Default)]
struct Recorder {
    opened: Mutex<Vec<(String, String)>>,
    renamed: Mutex<Vec<String>>,
}

impl Workspaces for Recorder {
    fn open(
        &self,
        key: &str,
        _session: &str,
        name: &str,
        group: &str,
        _cwd: &Path,
    ) -> Result<String, String> {
        self.opened
            .lock()
            .unwrap()
            .push((name.to_owned(), group.to_owned()));
        Ok(key.to_owned())
    }
    fn rename(&self, _key: &str, name: &str) -> Result<(), String> {
        self.renamed.lock().unwrap().push(name.to_owned());
        Ok(())
    }
    fn place(&self) -> String {
        "the test".into()
    }
    fn locate(&self, _key: &str) -> Option<workspaces::WorkspaceRef> {
        Some(workspaces::WorkspaceRef {
            id: "ws_cbd7f86ef04cb1b8d1f2f7a235d6538e".into(),
            session: "cmux-chief-h0me".into(),
        })
    }
}

/// "I don't like the checkmark": a finished subagent's workspace keeps the
/// name it was opened with; no title ever gets a ✓.
#[test]
fn a_finished_subagents_workspace_keeps_its_name_without_a_check_mark() {
    let mut h = Harness::new(default_script());
    let recorder = Arc::new(Recorder::default());
    let ws: Arc<dyn Workspaces> = recorder.clone();
    h.brain.set_workspaces(Some(ws.clone()));
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
        .with_workspaces(Some(ws)),
    );
    let worker = std::thread::spawn(move || {
        sp.spawn(vec!["Title: Sidebar group drag\nsay hello".into()], None)
    });
    let until = Instant::now() + Duration::from_secs(10);
    let status = |h: &Harness| h.brain.state().sub("a1").map(|(_, s)| s.status);
    let attached = |h: &Harness| {
        h.brain
            .state()
            .sub("a1")
            .is_some_and(|(_, s)| s.workspace.is_some() && s.status == SubStatus::Running)
    };
    while !(worker.is_finished() && attached(&h)) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    let answer = worker.join().unwrap().unwrap();
    assert!(
        attached(&h),
        "a1 never ran in its workspace: {:?}",
        status(&h)
    );
    // Its run ends (a failed prompt ends it at once, deterministically).
    h.tx.send(Input::SubagentAnswer {
        id: "a1".into(),
        answer: Err("the test ends it".into()),
    })
    .unwrap();
    let finished = |h: &Harness| matches!(status(h), Some(SubStatus::Done | SubStatus::Reported));
    while !finished(&h) && Instant::now() < until {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(10)) {
            h.brain.step(input);
        }
    }
    assert!(finished(&h), "a1 never finished: {:?}", status(&h));
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(200)) {
        h.brain.step(input);
    }
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        answer.contains("group \"Sidebar & tabs\""),
        "the spawn answer names the group: {answer}"
    );
    // a313: the reply gives the real ws_ id and how to move or pin it.
    assert!(
        answer.contains("ws_cbd7f86ef04cb1b8d1f2f7a235d6538e"),
        "the spawn answer gives the workspace's ws_ id: {answer}"
    );
    assert!(
        answer.contains(
            "cmux --session cmux-chief-h0me workspace ws_cbd7f86ef04cb1b8d1f2f7a235d6538e move --index 0"
        ),
        "the spawn answer says how to move it: {answer}"
    );
    assert_eq!(
        *recorder.opened.lock().unwrap(),
        vec![(
            "a1 · Sidebar group drag".to_owned(),
            "Sidebar & tabs".to_owned()
        )]
    );
    let renamed = recorder.renamed.lock().unwrap().clone();
    assert!(
        renamed.iter().all(|n| !n.contains('✓')),
        "no ✓ in any name: {renamed:?}"
    );
    assert!(renamed.is_empty(), "the name stays as opened: {renamed:?}");
}
