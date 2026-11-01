//! `_acpmux/chats_window`: a client's visible window over the chat index (P-RUST, 2026-10-30).
//!
//! acpmux owns the chat list a client shows: the order, the filter, the exclusions and the paging.
//! A client names a window and its spec and gets the window's rows; after each index or activity
//! change it gets a row diff: the window's keys in order and only the rows whose value changed,
//! with the next revision. A client never holds the whole index (the Mac app's whole-index mirror
//! copied and compared every chat on the main thread per change: hangs of 570 to 1,148 ms).
//!
//! Pure: the server keeps one [`WindowState`] per window and connection (`server/chat_windows.rs`).

use std::collections::{HashMap, HashSet};

use cmux_chat_index::{ChatIndex, IndexedChat};
use serde_json::{Value, json};

use super::{ChatActivity, ChatQuery, chat_value, key_text, parse_key};

/// What a window shows: `{window, gen?, query?, harness?, folder?, account?, limit?, topLevel?,
/// exclude?, keys?}`. `gen` is the client's generation of the window's spec: acpmux keeps the
/// highest it saw and echoes it in every message, so requests that run out of order never leave a
/// window on an older spec. With `keys`, exactly those chats in that order (a pinned list); otherwise
/// the newest chats the filter passes, none of `exclude`, at most `limit`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowSpec {
    pub window: String,
    /// The client's generation of this window's spec (0 from a client that sends none).
    pub generation: u64,
    filter: ChatQuery,
    /// Leaves out a chat another chat's agent started (`parent`): it folds under that chat.
    top_level: bool,
    exclude: HashSet<String>,
    keys: Option<Vec<String>>,
}

impl WindowSpec {
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let window = params
            .get("window")
            .and_then(Value::as_str)
            .filter(|w| !w.is_empty())
            .ok_or("window must be a non-empty string")?
            .to_owned();
        let filter = ChatQuery::from_params(params)?;
        let strings = |name: &str| -> Result<Option<Vec<String>>, String> {
            match params.get(name) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::Array(items)) => items
                    .iter()
                    .map(|item| item.as_str().map(str::to_owned))
                    .collect::<Option<Vec<_>>>()
                    .map(Some)
                    .ok_or_else(|| format!("{name} must be an array of chat keys")),
                Some(_) => Err(format!("{name} must be an array of chat keys")),
            }
        };
        let top_level = match params.get("topLevel") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(on)) => *on,
            Some(_) => return Err("topLevel must be true or false".to_owned()),
        };
        let generation = match params.get("gen") {
            None | Some(Value::Null) => 0,
            Some(value) => value.as_u64().ok_or("gen must be a non-negative number")?,
        };
        Ok(Self {
            window,
            generation,
            filter,
            top_level,
            exclude: strings("exclude")?.unwrap_or_default().into_iter().collect(),
            keys: strings("keys")?,
        })
    }
}

/// One row: the chat's key and its value as `_acpmux/chats` sends it (with its activity).
pub type Row = (String, Value);

/// A window's rows now, and whether more chats pass its filter past them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WindowRows {
    pub rows: Vec<Row>,
    pub has_more: bool,
}

/// The rows of `spec` in `index`: one walk of the index in its order (newest first) that stops
/// once the window is full and one more chat passes; a value is built only for a chat the filter
/// and the exclusions pass.
pub fn rows(spec: &WindowSpec, index: &ChatIndex, activity: &ChatActivity) -> WindowRows {
    let decorated = |chat: &IndexedChat| {
        let mut value = chat_value(chat);
        activity.decorate(&mut value);
        value
    };
    if let Some(keys) = &spec.keys {
        let rows = keys
            .iter()
            .filter_map(|text| {
                let chat = index.get(&parse_key(text)?)?;
                Some((text.clone(), decorated(chat)))
            })
            .collect();
        return WindowRows { rows, has_more: false };
    }
    let mut window = WindowRows::default();
    for chat in index.chats() {
        if !spec.filter.matches(chat) {
            continue;
        }
        let key = key_text(&chat.entry.key());
        if spec.exclude.contains(&key) {
            continue;
        }
        let value = decorated(chat);
        if spec.top_level && !value.get("parent").is_none_or(Value::is_null) {
            continue;
        }
        if window.rows.len() == spec.filter.limit {
            window.has_more = true;
            break;
        }
        window.rows.push((key, value));
    }
    window
}

/// What a window last sent its client, so the next message is a diff against it.
#[derive(Debug)]
pub struct WindowState {
    pub spec: WindowSpec,
    revision: u64,
    /// None until the window's first message: that one sends every row.
    sent: Option<WindowRows>,
}

impl WindowState {
    /// A new window, or a window whose spec changed: its next message sends every row. The
    /// revision goes on from `revision`, so a client never takes an older message for a newer.
    pub fn new(spec: WindowSpec, revision: u64) -> Self {
        Self { spec, revision, sent: None }
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The `_acpmux/chats_window_changed` params that bring the client from what it was sent to
    /// `next`, or None when it shows nothing new. The first message is `full` (every row); every
    /// later one is a diff: the window's keys in order and the rows whose value changed.
    pub fn next(&mut self, next: WindowRows) -> Option<Value> {
        let keys: Vec<&str> = next.rows.iter().map(|(key, _)| key.as_str()).collect();
        let message = match &self.sent {
            None => {
                let rows: Vec<&Value> = next.rows.iter().map(|(_, value)| value).collect();
                json!({"full": true, "keys": keys, "rows": rows})
            }
            Some(sent) => {
                if *sent == next {
                    return None;
                }
                let before: HashMap<&str, &Value> =
                    sent.rows.iter().map(|(key, value)| (key.as_str(), value)).collect();
                let changed: Vec<&Value> = next
                    .rows
                    .iter()
                    .filter(|(key, value)| before.get(key.as_str()) != Some(&value))
                    .map(|(_, value)| value)
                    .collect();
                json!({"full": false, "keys": keys, "rows": changed})
            }
        };
        self.revision = self.revision.saturating_add(1);
        let mut message = message;
        if let Some(object) = message.as_object_mut() {
            object.insert("window".into(), json!(self.spec.window));
            object.insert("gen".into(), json!(self.spec.generation));
            object.insert("revision".into(), json!(self.revision));
            object.insert("hasMore".into(), json!(next.has_more));
        }
        self.sent = Some(next);
        Some(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(params: Value) -> WindowSpec {
        WindowSpec::from_params(&params).unwrap()
    }

    fn row(key: &str, title: &str) -> Row {
        (key.to_owned(), json!({"key": key, "title": title}))
    }

    #[test]
    fn a_spec_needs_its_window_name_and_reads_its_lists() {
        assert!(WindowSpec::from_params(&json!({})).is_err());
        assert!(WindowSpec::from_params(&json!({"window": "w", "exclude": "x"})).is_err());
        assert!(WindowSpec::from_params(&json!({"window": "w", "topLevel": 1})).is_err());
        assert!(WindowSpec::from_params(&json!({"window": "w", "gen": -1})).is_err());
        assert_eq!(spec(json!({"window": "w", "gen": 7})).generation, 7);
        let s = spec(json!({"window": "w", "limit": 3, "exclude": ["a:1"], "keys": ["b:2"]}));
        assert_eq!(s.filter.limit, 3);
        assert!(s.exclude.contains("a:1"));
        assert_eq!(s.keys, Some(vec!["b:2".to_owned()]));
    }

    #[test]
    fn the_first_message_is_full_and_later_ones_carry_only_changed_rows() {
        let mut state = WindowState::new(spec(json!({"window": "w"})), 0);
        let first = WindowRows { rows: vec![row("a:1", "one"), row("a:2", "two")], has_more: true };
        let full = state.next(first.clone()).unwrap();
        assert_eq!(full["full"], true);
        assert_eq!(full["revision"], 1);
        assert_eq!(full["gen"], 0);
        assert_eq!(full["rows"].as_array().unwrap().len(), 2);
        assert_eq!(state.next(first), None, "nothing new, nothing sent");
        let moved = WindowRows {
            rows: vec![row("a:2", "two"), row("a:1", "one, renamed")],
            has_more: true,
        };
        let diff = state.next(moved).unwrap();
        assert_eq!(diff["full"], false);
        assert_eq!(diff["revision"], 2);
        assert_eq!(diff["keys"], json!(["a:2", "a:1"]));
        assert_eq!(diff["rows"], json!([{"key": "a:1", "title": "one, renamed"}]));
        let more = WindowRows {
            rows: vec![row("a:2", "two"), row("a:1", "one, renamed")],
            has_more: false,
        };
        let diff = state.next(more).unwrap();
        assert_eq!(diff["rows"], json!([]), "only hasMore changed");
        assert_eq!(diff["hasMore"], false);
    }

    #[test]
    fn a_replaced_spec_sends_every_row_again_with_a_later_revision() {
        let mut state = WindowState::new(spec(json!({"window": "w"})), 0);
        state.next(WindowRows { rows: vec![row("a:1", "one")], has_more: false });
        let mut replaced =
            WindowState::new(spec(json!({"window": "w", "limit": 5})), state.revision());
        let full =
            replaced.next(WindowRows { rows: vec![row("a:1", "one")], has_more: false }).unwrap();
        assert_eq!(full["full"], true);
        assert_eq!(full["revision"], 2);
    }
}
