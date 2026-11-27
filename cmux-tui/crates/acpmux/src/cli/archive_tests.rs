use super::*;

#[test]
fn each_session_says_what_changed() {
    let rows = vec![
        row("c-1", &json!({"name": "docs", "tags": {"archived": "1700"}, "changed": true}), true),
        row("c-2", &json!({"name": "", "tags": {"archived": "9"}, "changed": false}), true),
        row("c-3", &json!({"name": "api", "tags": {}, "changed": true}), false),
        row("c-4", &json!({"name": "web", "tags": {}, "changed": false}), false),
        row("c-5", &json!({"name": "old daemon", "tags": {}}), false),
    ];
    assert_eq!(rows[0]["archivedAt"], 1700);
    assert_eq!(rows[2]["archivedAt"], Value::Null);
    assert_eq!(rows[4]["changed"], Value::Null);
    assert_eq!(
        render(&rows),
        "archived docs\nc-2 was already archived\nunarchived api\nweb was not archived\n\
             unarchived old daemon\n"
    );
}
