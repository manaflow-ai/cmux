//! Picking sessions and fields out of the daemon's session records, so a script asks for what it
//! needs in one command instead of piping `--json` into python: `ls PATTERN`, `ls --tag`,
//! `--fields a,b.c` on `ls` and `session info`, and `send --tag`.

use anyhow::Result;
use serde_json::Value;

/// `--fields name, turn.activity` into its trimmed, non-empty field paths.
pub(crate) fn parse_fields(text: &str) -> Result<Vec<String>> {
    let fields: Vec<String> = text
        .split(',')
        .map(str::trim)
        .filter(|field| !field.is_empty())
        .map(str::to_owned)
        .collect();
    if fields.is_empty() {
        return Err(crate::cli::errors::AppError::usage(
            "--fields requires a comma-separated field list",
        )
        .into());
    }
    Ok(fields)
}

/// The value at `path` in a session record: a top-level key, or a dotted path into nested
/// objects and arrays (`turn.activity`, `lastMessage.text`, `pullRequests.0.number`). Keys may
/// hold dots themselves (the tag `lane.reportsTo`): the longest key that matches wins.
pub(crate) fn field<'a>(record: &'a Value, path: &str) -> Option<&'a Value> {
    if let Some(value) = record.get(path) {
        return Some(value);
    }
    let cuts = path.match_indices('.').map(|(i, _)| i).rev();
    cuts.filter_map(|i| {
        let (head, rest) = (path.get(..i)?, path.get(i..)?.strip_prefix('.')?);
        let next = match record {
            Value::Object(map) => map.get(head),
            Value::Array(rows) => head.parse::<usize>().ok().and_then(|n| rows.get(n)),
            _ => None,
        }?;
        field(next, rest)
    })
    .next()
}

/// The record cut down to `fields`, keyed by the path as given (`{"turn.activity": …}`). A
/// field the record lacks is left out.
pub(crate) fn project_fields(record: &Value, fields: &[String]) -> Value {
    let mut row = serde_json::Map::new();
    for path in fields {
        if let Some(value) = field(record, path) {
            row.insert(path.clone(), value.clone());
        }
    }
    Value::Object(row)
}

/// One field as plain text: a string as is, nothing for a missing or null field, JSON otherwise.
pub(crate) fn text_field(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(value) => serde_json::to_string(value).unwrap_or_default(),
    }
}

/// Whether the session carries `tag`: `key` (any value) or `key=value`. A tag is stored as a
/// string or as `{"value": …}`.
pub(crate) fn tag_matches(session: &Value, tag: &str) -> bool {
    let (key, want) = tag.split_once('=').map_or((tag, None), |(k, v)| (k, Some(v)));
    let Some(have) = session.get("tags").and_then(|tags| tags.get(key)) else {
        return false;
    };
    want.is_none_or(|w| {
        have.as_str() == Some(w) || have.get("value").and_then(Value::as_str) == Some(w)
    })
}

/// Whether the session matches any of `patterns`: a session id (bare, or a peer's `host/id`), or
/// a name glob (`*` any run, `?` one character). A pattern with a `/` is `host/glob`: it matches
/// only a peer's session, by its full `host/name` (a session here whose own name holds a `/` is
/// not on that host). One without matches the name on any host.
pub(crate) fn name_matches(session: &Value, patterns: &[String]) -> bool {
    let name = session.get("name").and_then(Value::as_str).unwrap_or("");
    let peer = session.get("peer").and_then(Value::as_str);
    let bare = match peer {
        Some(peer) => name.strip_prefix(peer).and_then(|n| n.strip_prefix('/')).unwrap_or(name),
        None => name,
    };
    let id = session.get("sessionId").and_then(Value::as_str);
    let qualified = session.get("qualifiedSessionId").and_then(Value::as_str);
    patterns.iter().any(|pattern| {
        id == Some(pattern.as_str())
            || qualified == Some(pattern.as_str())
            || if pattern.contains('/') {
                peer.is_some() && glob(pattern, name)
            } else {
                glob(pattern, bare)
            }
    })
}

/// Shell-style match of the whole `text` against `pattern` with `*` and `?`, linear time.
fn glob(pattern: &str, text: &str) -> bool {
    let (p, t): (Vec<char>, Vec<char>) = (pattern.chars().collect(), text.chars().collect());
    let (mut pi, mut ti) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while ti < t.len() {
        match p.get(pi) {
            Some('*') => {
                star = Some((pi, ti));
                pi += 1;
            }
            Some(&c) if c == '?' || t.get(ti) == Some(&c) => {
                pi += 1;
                ti += 1;
            }
            _ => match star {
                Some((sp, st)) => {
                    pi = sp + 1;
                    ti = st + 1;
                    star = Some((sp, st + 1));
                }
                None => return false,
            },
        }
    }
    p.get(pi..).unwrap_or_default().iter().all(|&c| c == '*')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn dotted_fields_reach_into_nested_records() {
        let info = json!({"name": "lane", "turn": {"activity": "Bash"}, "pullRequests": [{"number": 7}],
                          "a.b": 1, "tags": {"lane.reportsTo": "x", "area": "acpmux"}});
        assert_eq!(field(&info, "turn.activity"), Some(&json!("Bash")));
        assert_eq!(field(&info, "pullRequests.0.number"), Some(&json!(7)));
        assert_eq!(field(&info, "a.b"), Some(&json!(1)), "a dotted key wins over the path");
        assert_eq!(field(&info, "turn.missing"), None);
        assert_eq!(field(&info, "tags.lane.reportsTo"), Some(&json!("x")), "a dotted tag key");
        assert_eq!(field(&info, "tags.area"), Some(&json!("acpmux")));
        let wide = json!({"名前": {"子": 1}});
        assert_eq!(
            field(&wide, "名前.子"),
            Some(&json!(1)),
            "a dotted path through multibyte keys"
        );
        assert_eq!(field(&wide, "名前."), None);
        let fields = parse_fields("name, turn.activity,nope").unwrap();
        assert_eq!(
            project_fields(&info, &fields),
            json!({"name": "lane", "turn.activity": "Bash"})
        );
        assert!(parse_fields(" , ").is_err());
    }

    #[test]
    fn tags_match_by_key_or_key_and_value() {
        let s = json!({"tags": {"area": {"value": "acpmux"}, "role": "review"}});
        assert!(tag_matches(&s, "area"));
        assert!(tag_matches(&s, "area=acpmux"));
        assert!(tag_matches(&s, "role=review"));
        assert!(!tag_matches(&s, "area=cloud"));
        assert!(!tag_matches(&s, "task"));
    }

    #[test]
    fn names_match_globs_bare_or_host_qualified_and_ids() {
        let local = json!({"name": "review-27899", "sessionId": "01a1"});
        let peer = json!({"name": "huge-blue/review-27800-b", "peer": "huge-blue", "sessionId": "01b2",
                          "qualifiedSessionId": "huge-blue/01b2"});
        let p = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(name_matches(&local, &p(&["review-27*"])));
        assert!(name_matches(&peer, &p(&["review-27*"])), "a bare pattern matches on any host");
        assert!(name_matches(&peer, &p(&["huge-blue/*"])));
        assert!(!name_matches(&local, &p(&["huge-blue/*"])));
        let slashed = json!({"name": "huge-blue/notes", "sessionId": "01c3"});
        assert!(
            !name_matches(&slashed, &p(&["huge-blue/*"])),
            "a local name with a / is not a peer's"
        );
        assert!(name_matches(&slashed, &p(&["01c3"])));
        assert!(name_matches(&local, &p(&["review-2789?"])));
        assert!(!name_matches(&local, &p(&["review"])), "a glob matches the whole name");
        // Multibyte names and patterns: `?` is one char, and a trailing `*` matches nothing.
        let wide = json!({"name": "レビュー-27", "sessionId": "01d4"});
        assert!(name_matches(&wide, &p(&["レビュー-2?"])));
        assert!(name_matches(&wide, &p(&["レ*"])));
        assert!(name_matches(&wide, &p(&["レビュー-27*"])));
        assert!(!name_matches(&wide, &p(&["レビ"])));
        assert!(name_matches(&local, &p(&["nope", "01a1"])), "an id matches exactly");
        assert!(name_matches(&peer, &p(&["huge-blue/01b2"])), "a peer's host/id matches");
        assert!(!name_matches(&peer, &p(&["other/01b2"])));
        assert!(glob("*", ""));
        assert!(glob("a*b*c", "axxbyyc"));
        assert!(!glob("a*b*c", "axxbyy"));
    }
}
