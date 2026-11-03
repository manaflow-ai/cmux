//! What the Chief has running, for the person (Leo 2026-11-02: "how about being able to see
//! background tasks and subagents within the chief ui?"): its subagents (the ones at work and
//! the ones that ended in the last 2 h, like `control status`), the watches it started with
//! `watch` and their last output lines, and the wakes it asked for with `sleep`. The memory
//! inspector's `/api/activity` asks for it through the tools socket's `inspect` tool, and its
//! Running tab draws it. Read-only: building it starts, refreshes or writes nothing.

use serde_json::{Value, json};

use super::Brain;
use crate::state::{SubRecord, SubStatus, Wake, Watch};

/// How long an ended subagent stays listed (the same window as `control status`).
pub const ENDED_KEPT_MS: u64 = 2 * 3600 * 1000;
/// Most subagents listed, newest first.
pub const SUBAGENTS_SHOWN: usize = 40;

/// One subagent as the brain sees it now.
pub struct SubRow<'a> {
    pub sub: &'a SubRecord,
    /// `state_of`: thinking, running-tool, waiting, done, failed...
    pub state: &'static str,
    /// The last line its agent wrote (its run watch), if any.
    pub last_line: Option<&'a str>,
    /// Its chat's deeplink (`cmux://chief/<home>/session/<session>`), when it has a session.
    pub link: Option<String>,
}

/// The activity answer: `{"now_ms", "subagents": [..], "watches": [..], "wakes": [..]}`.
/// Subagents newest first (by number), ended ones older than [`ENDED_KEPT_MS`] left out;
/// watches oldest first, each with `latest`, its last output lines; wakes soonest first.
pub fn build(
    now: u64,
    subs: Vec<SubRow<'_>>,
    watches: &[Watch],
    latest: &dyn Fn(&str) -> Vec<String>,
    wakes: &[Wake],
) -> Value {
    let mut subs: Vec<SubRow<'_>> = subs
        .into_iter()
        .filter(|r| {
            r.sub.status != SubStatus::Reported
                || now.saturating_sub(r.sub.run_ms) < ENDED_KEPT_MS
        })
        .collect();
    subs.sort_by_key(|r| std::cmp::Reverse(number(&r.sub.id)));
    let total = subs.len();
    let subagents: Vec<Value> = subs
        .iter()
        .take(SUBAGENTS_SHOWN)
        .map(|r| {
            let s = r.sub;
            json!({
                "id": s.id,
                "title": s.title,
                "state": r.state,
                "at_work": s.at_work(),
                "started_ms": s.run_ms,
                "last_line": r.last_line,
                "link": r.link,
                "hidden": s.workspace.is_none(),
                "waiting_on_you": s.permission.is_some(),
                "report": s.report.as_deref().filter(|_| !s.at_work()).map(|t| clip(t, 400)),
            })
        })
        .collect();
    let mut wakes: Vec<&Wake> = wakes.iter().collect();
    wakes.sort_by_key(|w| w.at_ms);
    json!({
        "now_ms": now,
        "subagents": subagents,
        "more_subagents": total.saturating_sub(SUBAGENTS_SHOWN),
        "watches": watches.iter().map(|w| json!({
            "id": w.id,
            "command": w.command,
            "until": w.until,
            "note": w.note,
            "asked_ms": w.asked_ms,
            "deadline_ms": w.deadline_ms,
            "latest": latest(&w.id),
        })).collect::<Vec<_>>(),
        "wakes": wakes.iter().map(|w| json!({
            "at_ms": w.at_ms,
            "asked_ms": w.asked_ms,
            "note": w.note,
            "until_event": w.until_event,
        })).collect::<Vec<_>>(),
    })
}

/// `a12` -> 12; anything else sorts last.
fn number(id: &str) -> u64 {
    id.trim_start_matches('a').parse().unwrap_or(0)
}

/// `text` on one line, at most `max` characters.
fn clip(text: &str, max: usize) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    match line.char_indices().nth(max) {
        Some((cut, _)) => format!("{}…", &line[..cut]),
        None => line,
    }
}

impl Brain {
    /// What the Chief has running now ([`build`]), from what the brain already holds: no
    /// acpmux read, so asking never slows the run loop.
    pub(super) fn activity(&self) -> Value {
        let now = self.now();
        let rows: Vec<SubRow<'_>> = self
            .state
            .spawns
            .values()
            .flat_map(|r| r.subs.iter())
            .map(|sub| SubRow {
                sub,
                state: self.state_of(sub, now),
                last_line: self.watches.get(&sub.id).and_then(|w| w.last_line()),
                link: sub.session_id.as_deref().and_then(|session| {
                    crate::workspaces::subagent_link(&self.settings.parent, &sub.id, session)
                        .and_then(|md| md.split_once("](").map(|(_, url)| url.trim_end_matches(')').to_owned()))
                }),
            })
            .collect();
        let latest = |id: &str| {
            self.watch_runs
                .get(id)
                .map(|r| r.latest())
                .unwrap_or_default()
        };
        build(now, rows, &self.state.watches, &latest, &self.state.wakes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sub(id: &str, status: SubStatus, run_ms: u64) -> SubRecord {
        SubRecord {
            id: id.into(),
            title: format!("task {id}"),
            status,
            run_ms,
            session_id: Some(format!("s-{id}")),
            workspace: Some("ws".into()),
            ..SubRecord::default()
        }
    }

    #[test]
    fn lists_running_subagents_newest_first_and_drops_old_ended_ones() {
        let now = 10 * 3600 * 1000;
        let (a2, a10, a3) = (
            sub("a2", SubStatus::Running, now - 60_000),
            sub("a10", SubStatus::Running, now - 5_000),
            sub("a3", SubStatus::Reported, now - 3 * 3600 * 1000),
        );
        let rows = vec![
            SubRow { sub: &a2, state: "running-tool", last_line: Some("cargo test"), link: Some("cmux://chief/0123abcd/session/s-a2".into()) },
            SubRow { sub: &a3, state: "done", last_line: None, link: None },
            SubRow { sub: &a10, state: "thinking", last_line: None, link: None },
        ];
        let v = build(now, rows, &[], &|_| Vec::new(), &[]);
        let ids: Vec<&str> = v["subagents"].as_array().unwrap().iter().map(|s| s["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["a10", "a2"]);
        let a2 = &v["subagents"][1];
        assert_eq!(a2["title"], "task a2");
        assert_eq!(a2["state"], "running-tool");
        assert_eq!(a2["started_ms"], now - 60_000);
        assert_eq!(a2["last_line"], "cargo test");
        assert_eq!(a2["link"], "cmux://chief/0123abcd/session/s-a2");
        assert_eq!(a2["at_work"], true);
        assert_eq!(v["now_ms"], now);
    }

    #[test]
    fn a_recently_ended_subagent_shows_its_report() {
        let now = 10 * 3600 * 1000;
        let mut done = sub("a4", SubStatus::Reported, now - 600_000);
        done.report = Some("landed #123\nas abc".into());
        let v = build(now, vec![SubRow { sub: &done, state: "done", last_line: None, link: None }], &[], &|_| Vec::new(), &[]);
        assert_eq!(v["subagents"][0]["report"], "landed #123 as abc");
        assert_eq!(v["subagents"][0]["at_work"], false);
    }

    #[test]
    fn lists_watches_with_their_last_output_and_wakes_soonest_first() {
        let watches = vec![Watch {
            id: "w4".into(),
            command: "gh pr view 1 --json state".into(),
            until: Some("MERGED".into()),
            note: "tell a26".into(),
            asked_ms: 1,
            deadline_ms: 9,
        }];
        let wakes = vec![
            Wake { at_ms: 50, asked_ms: 1, note: "later".into(), until_event: false },
            Wake { at_ms: 20, asked_ms: 1, note: "sooner".into(), until_event: true },
        ];
        let latest = |id: &str| if id == "w4" { vec!["OPEN".to_owned()] } else { Vec::new() };
        let v = build(100, Vec::new(), &watches, &latest, &wakes);
        assert_eq!(v["watches"][0]["id"], "w4");
        assert_eq!(v["watches"][0]["until"], "MERGED");
        assert_eq!(v["watches"][0]["latest"], json!(["OPEN"]));
        assert_eq!(v["wakes"][0]["note"], "sooner");
        assert_eq!(v["wakes"][0]["until_event"], true);
        assert_eq!(v["wakes"][1]["note"], "later");
    }
}
