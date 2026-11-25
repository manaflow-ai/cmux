//! Organizer's first slice: a read-only projection of local sessions on branches.
//! No polling, new daemon state, git subprocesses, or network joins. The existing Labs switch
//! gates the read before connecting; the session list's own bounded transport does the census.

use std::collections::BTreeMap;

use acpmux_client::wire::ListView;
use anyhow::Result;
use serde_json::{Value, json};

use super::ls_pages::{self, Plan, Step};
use crate::cli::errors::{AppError, Code};
use crate::cli::{list_read, output::print_json};
use crate::rpc::method;
use crate::user_settings::{self, Settings};

const STALE_AFTER_MS: u64 = 6 * 60 * 60 * 1000;

fn enabled(settings: &Settings) -> bool {
    matches!(settings, Settings::Parsed(doc)
        if user_settings::value(doc, "labs.previewFeatures") == Some(Value::Bool(true)))
}

pub(super) async fn run(_json_out: bool) -> Result<()> {
    if !enabled(&user_settings::read()) {
        return Err(AppError::new(
            Code::Usage,
            "experiment_disabled",
            "Organizer is off. Enable Show Preview Features in Settings > Experimental > Labs.\nnext: cmux settings set labs.previewFeatures true",
        )
        .into());
    }
    // A read must not start or warm agents, or start a daemon of its own.
    let client = crate::daemon::connect_running().await?;
    let rows = match list_read::Via::daemon().open(&client).await? {
        Some(mut source) => {
            source.rows(ListView::Live, &|summary| summary.origin == "local").await?
        }
        None => {
            let fetch = |params| {
                let client = client.clone();
                async move { client.request(method::MUX_SESSIONS, params).await }
            };
            ls_pages::read(
                json!({"localOnly": true, "excludeStatus": ["closed"]}),
                None,
                Plan { size: ls_pages::PAGE_ROWS, want: None, one: false, exact: false },
                |row| if eligible(row) { Step::Keep } else { Step::Skip },
                fetch,
            )
            .await?
            .rows
        }
    };
    // The interface is JSON even without --json: agents and people read the same projection.
    print_json(&project(&rows, crate::store::now_ms()));
    Ok(())
}

fn text<'a>(row: &'a Value, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn tagged(row: &Value, key: &str) -> bool {
    row.get("tags").and_then(|tags| tags.get(key)).is_some_and(|v| !v.is_null())
}

fn eligible(row: &Value) -> bool {
    text(row, "peer").is_none()
        && row["status"] != "closed"
        && row["archived"] != true
        && row["side"] != true
        && !["archived", "side", "aside"].into_iter().any(|key| tagged(row, key))
        && text(row, "sessionId").is_some()
        && text(row, "cwd").is_some()
        && text(row, "gitBranch").is_some()
}

/// Idle bookkeeping does not refresh a claim. A wait ages from its start; a running turn
/// uses its latest record, and idle/disconnected sessions use their actual turn timestamps.
fn activity_at(row: &Value) -> Option<u64> {
    let time = |v: &Value| v.as_u64().filter(|t| *t > 0);
    let at = |pointer: &str| row.pointer(pointer).and_then(time);
    if let Some(waiting) = at("/inputSince") {
        return Some(waiting);
    }
    let status = row.get("status").and_then(Value::as_str);
    if status == Some("running") || status == Some("waiting") {
        return at("/updatedAt");
    }
    [at("/turn/startedAt"), at("/lastTurn/endedAt"), at("/createdAt")].into_iter().flatten().max()
}

#[derive(Default)]
struct Card {
    sessions: BTreeMap<String, Value>,
    last_activity: Option<u64>,
    unknown_activity: bool,
}

fn project(rows: &[Value], now: u64) -> Value {
    // Folder plus branch is deliberately conservative: equal branch names in unrelated repos
    // must not claim each other's work. Resolving common git dirs across worktrees is deferred.
    let mut cards: BTreeMap<(String, String), Card> = BTreeMap::new();
    for row in rows.iter().filter(|row| eligible(row)) {
        let (Some(cwd), Some(branch), Some(id)) =
            (text(row, "cwd"), text(row, "gitBranch"), text(row, "sessionId"))
        else {
            continue;
        };
        let activity = activity_at(row);
        let card = cards.entry((cwd.into(), branch.into())).or_default();
        card.last_activity = card.last_activity.max(activity);
        card.unknown_activity |= activity.is_none();
        card.sessions.insert(
            id.into(),
            json!({
                "sessionId": id,
                "name": text(row, "name"),
                "harness": text(row, "harness"),
                "status": row.get("status"),
                "activityAt": activity,
            }),
        );
    }
    let cards: Vec<Value> = cards
        .into_iter()
        .map(|((cwd, branch), card)| {
            let stale = !card.unknown_activity
                && card.last_activity.is_some_and(|at| now.saturating_sub(at) >= STALE_AFTER_MS);
            json!({
                "id": json!(["branch", cwd, branch]).to_string(),
                "cwd": cwd,
                "branch": branch,
                "column": if stale { "stale" } else { "claimed" },
                "activityAt": card.last_activity,
                "sessions": card.sessions.into_values().collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({
        "version": 1,
        "scope": "local",
        "observedAt": now,
        "staleAfterMs": STALE_AFTER_MS,
        "columns": ["claimed", "stale"],
        "cards": cards,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str, cwd: &str, branch: &str, at: u64) -> Value {
        json!({"sessionId": id, "cwd": cwd, "gitBranch": branch, "status": "idle",
            "createdAt": 1, "lastTurn": {"endedAt": at}, "updatedAt": u64::MAX})
    }

    #[test]
    fn organizer_board_is_off_unless_labs_explicitly_true() {
        for settings in [
            Settings::Missing,
            Settings::Unreadable("bad file".into()),
            Settings::Parsed(json!({})),
            Settings::Parsed(json!({"labs.previewFeatures": "true"})),
            Settings::Parsed(json!({"labs": {"previewFeatures": false}})),
        ] {
            assert!(!enabled(&settings));
        }
        assert!(enabled(&Settings::Parsed(json!({"labs": {"previewFeatures": true}}))));
        assert!(enabled(&Settings::Parsed(json!({"labs.previewFeatures": true}))));
    }

    #[test]
    fn organizer_board_groups_claimants_without_joining_unrelated_folders() {
        let rows = [
            session("b", "/one", "fix", 10),
            session("a", "/one", "fix", 20),
            session("c", "/two", "fix", 30),
        ];
        let board = project(&rows, 40);
        assert_eq!(board["cards"].as_array().unwrap().len(), 2);
        assert_eq!(board["cards"][0]["sessions"][0]["sessionId"], "a");
        assert_eq!(board["cards"][0]["sessions"].as_array().unwrap().len(), 2);
        assert_eq!(board["cards"][0]["activityAt"], 20);
        let reversed: Vec<_> = rows.into_iter().rev().collect();
        assert_eq!(board, project(&reversed, 40));
    }

    #[test]
    fn organizer_board_staleness_uses_activity_and_latest_claimant() {
        let now = STALE_AFTER_MS + 100;
        let old = session("old", "/one", "fix", 100);
        assert_eq!(project(std::slice::from_ref(&old), now)["cards"][0]["column"], "stale");
        let recent = session("recent", "/one", "fix", 101);
        assert_eq!(project(&[old, recent], now)["cards"][0]["column"], "claimed");
        let mut waiting = session("wait", "/one", "fix", 200);
        waiting["status"] = json!("running");
        waiting["inputSince"] = json!(100);
        assert_eq!(project(&[waiting], now)["cards"][0]["column"], "stale");
        let unknown = json!({"sessionId": "u", "cwd": "/one", "gitBranch": "fix"});
        assert_eq!(project(&[unknown], now)["cards"][0]["column"], "claimed");
        assert_eq!(
            project(&[session("future", "/one", "fix", now + 1)], now)["cards"][0]["column"],
            "claimed"
        );
    }

    #[test]
    fn organizer_board_excludes_remote_closed_archived_side_and_unidentified_work() {
        let base = session("a", "/one", "fix", 1);
        let mut excluded = Vec::new();
        for (key, value) in [
            ("peer", json!("other")),
            ("status", json!("closed")),
            ("archived", json!(true)),
            ("side", json!(true)),
            ("gitBranch", Value::Null),
            ("cwd", json!("")),
            ("sessionId", Value::Null),
            ("tags", json!({"aside": true})),
            ("tags", json!({"archived": "yes"})),
        ] {
            let mut row = base.clone();
            row[key] = value;
            excluded.push(row);
        }
        assert_eq!(project(&excluded, 100)["cards"], json!([]));
    }
}
