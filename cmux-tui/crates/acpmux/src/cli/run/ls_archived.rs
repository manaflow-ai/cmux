//! `acpmux ls --archived`: only the archived chats (the tag `archived`, valued with when, Unix
//! ms; `hub/inactive_archive.rs`), the newest archive first, each with when it was archived and
//! whether the daemon archived it on its own (`archivedBy=auto`, the setting
//! `agents.chats.archiveInactive`). `--json` rows carry `archivedAt` (null for an archive whose
//! tag holds no time, as an older client's `1`) and `archivedBy` (`auto` or `person`).

use serde_json::Value;

/// The tag an archived chat carries (`hub/inactive_archive.rs` `ARCHIVED_TAG`).
const ARCHIVED_TAG: &str = "archived";
/// Who archived it, when not the person (`hub/inactive_archive.rs` `ARCHIVED_BY_TAG`).
const ARCHIVED_BY_TAG: &str = "archivedBy";

fn tag<'a>(row: &'a Value, key: &str) -> Option<&'a Value> {
    row.get("tags").and_then(|t| t.get(key))
}

/// The tag's value: a string, or an object's `value` (a tag listed with its expiry).
fn tag_text<'a>(row: &'a Value, key: &str) -> Option<&'a str> {
    let tag = tag(row, key)?;
    tag.as_str().or_else(|| tag.get("value").and_then(Value::as_str))
}

/// Whether `row` is archived, as the app reads the tag (`AgentChatDetail.archived`): any value
/// but empty or `false`.
pub(super) fn archived(row: &Value) -> bool {
    match tag(row, ARCHIVED_TAG) {
        None => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => tag_text(row, ARCHIVED_TAG).is_none_or(|v| !v.is_empty() && v != "false"),
    }
}

/// When `row` was archived (Unix ms), when its tag says.
fn archived_at(row: &Value) -> Option<u64> {
    tag_text(row, ARCHIVED_TAG).and_then(|v| v.parse::<u64>().ok()).filter(|at| *at > 1)
}

fn archived_by(row: &Value) -> &'static str {
    if tag_text(row, ARCHIVED_BY_TAG) == Some("auto") { "auto" } else { "person" }
}

fn name(row: &Value) -> &str {
    row.get("name").and_then(Value::as_str).unwrap_or("")
}

/// The archived rows of `rows`, each with `archivedAt` and `archivedBy`, the newest archive
/// first (one with no time last), then by name.
pub(super) fn rows(rows: Vec<Value>) -> Vec<Value> {
    let mut out: Vec<(Option<u64>, Value)> = rows
        .into_iter()
        .filter(archived)
        .map(|mut row| {
            let at = archived_at(&row);
            let by = archived_by(&row);
            if let Some(obj) = row.as_object_mut() {
                obj.insert("archivedAt".to_owned(), at.map_or(Value::Null, Value::from));
                obj.insert("archivedBy".to_owned(), Value::from(by));
            }
            (at, row)
        })
        .collect();
    out.sort_by(|(a, x), (b, y)| b.cmp(a).then_with(|| name(x).cmp(name(y))));
    out.into_iter().map(|(_, row)| row).collect()
}

/// How long ago `at` was, from `now` (both in ms): `12s ago`, `4m ago`, `3h ago`, `2d ago`.
fn ago(now: u64, at: u64) -> String {
    let s = now.saturating_sub(at) / 1000;
    let n = match s {
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m", s / 60),
        3600..86_400 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86_400),
    };
    format!("{n} ago")
}

/// The text view: one line a chat, `NAME  HOST  ARCHIVED  BY  STATUS`.
pub(super) fn render(rows: &[Value], now: u64) -> String {
    if rows.is_empty() {
        return "no archived chats\n".to_owned();
    }
    let text = |row: &Value, key: &str| {
        row.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    let lines: Vec<[String; 5]> = rows
        .iter()
        .map(|row| {
            [
                text(row, "name").or_else(|| text(row, "sessionId")).unwrap_or_else(|| "-".into()),
                text(row, "peer").unwrap_or_else(|| "local".into()),
                row.get("archivedAt").and_then(Value::as_u64).map_or("-".into(), |at| ago(now, at)),
                text(row, "archivedBy").unwrap_or_else(|| "person".into()),
                text(row, "status").unwrap_or_else(|| "-".into()),
            ]
        })
        .collect();
    let head = ["NAME", "HOST", "ARCHIVED", "BY", "STATUS"].map(str::to_owned);
    let mut widths = [0usize; 4];
    for line in std::iter::once(&head).chain(&lines) {
        for (w, c) in widths.iter_mut().zip(line.iter()) {
            *w = (*w).max(c.chars().count());
        }
    }
    let mut out = String::new();
    for line in std::iter::once(&head).chain(&lines) {
        for (c, w) in line.iter().zip(widths) {
            out.push_str(&format!("{c:<w$}  "));
        }
        out.push_str(line.last().map_or("", String::as_str));
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
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
            row(
                "docs",
                json!({"archived": (now - 3 * 3_600_000).to_string(), "archivedBy": "auto"}),
            ),
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
}
