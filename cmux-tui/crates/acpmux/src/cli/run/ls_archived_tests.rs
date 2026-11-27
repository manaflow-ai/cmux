use super::*;
use serde_json::json;

fn row(name: &str, tags: Value) -> Value {
    json!({"sessionId": format!("c-{name}"), "name": name, "status": "closed", "tags": tags})
}

#[test]
fn only_archived_rows_newest_archive_first() {
    let listed = rows(vec![
        row("live", json!({})),
        row("old", json!({"archived": "1000"})),
        row("auto", json!({"archived": "3000", "archivedBy": "auto"})),
        row("legacy", json!({"archived": "1"})),
        row("undone", json!({"archived": "false"})),
        row("emptied", json!({"archived": ""})),
        row("expiring", json!({"archived": {"value": "2000", "expires_at": 9}})),
    ]);
    let names: Vec<&str> = listed.iter().map(name).collect();
    assert_eq!(names, ["auto", "expiring", "old", "legacy"]);
    assert_eq!(listed[0]["archivedAt"], 3000);
    assert_eq!(listed[0]["archivedBy"], "auto");
    assert_eq!(listed[2]["archivedBy"], "person");
    assert_eq!(listed[3]["archivedAt"], Value::Null);
}

#[test]
fn the_text_view_says_when_and_by_whom() {
    let now = 10 * 86_400_000;
    let listed = rows(vec![
        row("docs", json!({"archived": (now - 3 * 3_600_000).to_string(), "archivedBy": "auto"})),
        row("legacy", json!({"archived": "1"})),
    ]);
    assert_eq!(
        render(&listed, now),
        "NAME    HOST   ARCHIVED  BY      STATUS\n\
             docs    local  3h ago    auto    closed\n\
             legacy  local  -         person  closed\n"
    );
    assert_eq!(render(&[], now), "no archived chats\n");
}
