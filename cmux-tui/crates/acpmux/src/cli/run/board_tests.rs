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
