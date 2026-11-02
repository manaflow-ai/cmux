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
/// window on an older spec. With `keys`, exactly those chats in that order (a pinned list); with a
/// `query`, the chats the palette's own ranker (`cmux-palette-ranker`: match tiers, typos, every word
/// anywhere) finds in their title, folder and harness, best match first, and the `total` that
/// matched; otherwise the newest chats the filter passes, none of `exclude`, at most `limit`.
/// `untitled` is the title a chat with none shows (the client's own word, so a query finds it).
/// `history` is the client's choice history as JSON text, `{now, frecency}` in the palette
/// ranker's own shape (`cmux_palette_ranker::Frecency`, keys `chat:<key>`), so a chat the person
/// chose before ranks as it did in the palette. `count` makes a no-query window report the
/// `total` of chats it could show, so a client can say how many more there are.
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
    /// The typed query, ranked by the palette ranker (the filter's own substring text is off).
    query: Option<String>,
    untitled: String,
    /// The client's choice history, parsed once when the spec is read.
    history: Option<ParsedHistory>,
    count: bool,
}

/// The client's choice history: the palette ranker's frecency and the clock it is read at.
#[derive(serde::Deserialize)]
struct History {
    now: f64,
    frecency: cmux_palette_ranker::Frecency,
}

/// A spec's history, parsed once. Two specs are equal when the client sent the same text (the
/// parsed form has no equality of its own: floats and maps).
#[derive(Clone, Debug)]
struct ParsedHistory {
    text: String,
    now: f64,
    frecency: cmux_palette_ranker::Frecency,
}

impl PartialEq for ParsedHistory {
    fn eq(&self, other: &Self) -> bool {
        self.text == other.text
    }
}

impl Eq for ParsedHistory {}

impl WindowSpec {
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let window = params
            .get("window")
            .and_then(Value::as_str)
            .filter(|w| !w.is_empty())
            .ok_or("window must be a non-empty string")?
            .to_owned();
        let mut filter = ChatQuery::from_params(params)?;
        // The query is ranked (`rank`), not the filter's substring match.
        let query = params
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|q| !q.is_empty())
            .map(|q| q.chars().take(512).collect::<String>());
        filter.text = None;
        let untitled = params
            .get("untitled")
            .and_then(Value::as_str)
            .map(|u| u.chars().take(64).collect())
            .unwrap_or_default();
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
        let history = match params.get("history") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => {
                let history = serde_json::from_str::<History>(text)
                    .map_err(|e| format!("history must be {{now, frecency}} JSON: {e}"))?;
                Some(ParsedHistory {
                    text: text.clone(),
                    now: history.now,
                    frecency: history.frecency,
                })
            }
            Some(_) => return Err("history must be a JSON string".to_owned()),
        };
        let count = match params.get("count") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(on)) => *on,
            Some(_) => return Err("count must be true or false".to_owned()),
        };
        Ok(Self {
            window,
            generation,
            filter,
            top_level,
            exclude: strings("exclude")?.unwrap_or_default().into_iter().collect(),
            keys: strings("keys")?,
            query,
            untitled,
            history,
            count,
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
    /// How many chats matched the query (a query window only), so a client can say that more
    /// match than it shows.
    pub total: Option<usize>,
}

/// One chat as the palette ranker reads it: what the palette's chats page showed and searched
/// (its title, its folder with `~` for the home folder, and the harness and folder as keywords),
/// and its frecency key (`chat:<key>`, the palette row's id the choice history is kept under).
pub fn rank_entry(
    key: &str,
    title: Option<&str>,
    untitled: &str,
    cwd: Option<&str>,
    harness: &str,
    home: Option<&str>,
) -> cmux_palette_ranker::Entry {
    let subtitle = cwd.map(|cwd| match home {
        Some(home) if !home.is_empty() && (cwd == home || cwd.starts_with(&format!("{home}/"))) => {
            format!("~{}", &cwd[home.len()..])
        }
        _ => cwd.to_owned(),
    });
    let mut keywords = vec![harness.to_owned()];
    keywords.extend(cwd.map(str::to_owned));
    cmux_palette_ranker::Entry {
        title: title.filter(|t| !t.is_empty()).unwrap_or(untitled).to_owned(),
        keywords,
        subtitle,
        frecency_key: Some(format!("chat:{key}")),
        ..Default::default()
    }
}

/// The indexes of `entries` the palette ranker finds for `query`, best match first, all of them,
/// with the client's choice history (`frecency` at `now`) as the palette ranked with it.
pub fn ranked(
    query: &str,
    entries: Vec<cmux_palette_ranker::Entry>,
    history: Option<(f64, cmux_palette_ranker::Frecency)>,
) -> Vec<usize> {
    let count = i64::try_from(entries.len()).unwrap_or(i64::MAX);
    let (now, frecency) =
        history.map_or((None, None), |(now, frecency)| (Some(now), Some(frecency)));
    let request = cmux_palette_ranker::RankRequest {
        operation: "rank".to_owned(),
        query: Some(query.to_owned()),
        frecency,
        now,
        row_limit: Some(count),
        highlight_limit: Some(0),
        entries: Some(entries),
        ..Default::default()
    };
    let mut rows: Vec<(i64, usize)> = Vec::new();
    for section in cmux_palette_ranker::rank_request(&request) {
        rows.extend(section.rows.into_iter().map(|row| (row.score, row.index)));
    }
    // Every entry is in section 0, so this is the ranker's own order; kept stable by position.
    rows.into_iter().map(|(_, index)| index).collect()
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
        return WindowRows { rows, has_more: false, total: None };
    }
    if let Some(query) = &spec.query {
        return ranked_rows(spec, query, index, activity);
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
        if spec.top_level && activity.has_parent(&key) {
            continue;
        }
        if window.rows.len() == spec.filter.limit {
            window.has_more = true;
            if !spec.count {
                break;
            }
            // Counted only: no value is built for a chat past the page.
            *window.total.get_or_insert(window.rows.len()) += 1;
            continue;
        }
        window.rows.push((key, decorated(chat)));
    }
    if spec.count {
        window.total.get_or_insert(window.rows.len());
    }
    window
}

/// A query window: every chat the filter and the exclusions pass, ranked by the palette ranker,
/// the first `limit` of them and the total that matched.
fn ranked_rows(
    spec: &WindowSpec,
    query: &str,
    index: &ChatIndex,
    activity: &ChatActivity,
) -> WindowRows {
    let home = dirs::home_dir().map(|home| home.to_string_lossy().trim_end_matches('/').to_owned());
    let mut candidates: Vec<(String, Value)> = Vec::new();
    let mut entries = Vec::new();
    for chat in index.chats() {
        if !spec.filter.matches(chat) {
            continue;
        }
        let key = key_text(&chat.entry.key());
        if spec.exclude.contains(&key) {
            continue;
        }
        let mut value = chat_value(chat);
        activity.decorate(&mut value);
        if spec.top_level && !value.get("parent").is_none_or(Value::is_null) {
            continue;
        }
        let entry = &chat.entry;
        entries.push(rank_entry(
            &key,
            entry.title.as_deref(),
            &spec.untitled,
            entry.cwd.as_deref(),
            entry.harness.id(),
            home.as_deref(),
        ));
        candidates.push((key, value));
    }
    let order = ranked(query, entries, spec.history.as_ref().map(|h| (h.now, h.frecency.clone())));
    let total = order.len();
    let mut slots: Vec<Option<(String, Value)>> = candidates.into_iter().map(Some).collect();
    let rows = order
        .into_iter()
        .take(spec.filter.limit)
        .filter_map(|i| slots.get_mut(i).and_then(Option::take))
        .collect();
    WindowRows { rows, has_more: total > spec.filter.limit, total: Some(total) }
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
            if let Some(total) = next.total {
                object.insert("total".into(), json!(total));
            }
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

    fn entry(title: &str, cwd: &str, harness: &str) -> cmux_palette_ranker::Entry {
        rank_entry(
            &format!("{harness}:{title}"),
            Some(title),
            "New chat",
            Some(cwd),
            harness,
            Some("/Users/me"),
        )
    }

    /// The palette's chats page found a chat by its harness and by words anywhere in it (review of
    /// #28090: a substring search lost both); the window ranks with the same ranker.
    #[test]
    fn a_query_finds_chats_by_harness_and_by_words_that_are_not_adjacent() {
        let entries = || {
            vec![
                entry("Fix the flaky build", "/Users/me/cmux", "claude-code"),
                entry("Port the parser", "/Users/me/tools", "codex"),
                entry("Write the docs", "/Users/me/site", "codex"),
            ]
        };
        let mut codex = ranked("codex", entries(), None);
        codex.sort_unstable();
        assert_eq!(codex, vec![1, 2], "a harness name finds that harness's chats");
        assert_eq!(
            ranked("fix build", entries(), None),
            vec![0],
            "two words that are not next to each other"
        );
        assert_eq!(ranked("tools", entries(), None), vec![1], "the folder");
        let untitled = rank_entry("codex:u", None, "New chat", None, "codex", None);
        assert_eq!(
            ranked("new chat", vec![untitled], None),
            vec![0],
            "an untitled chat by the client's word"
        );
    }

    /// The palette ranked a chat the person chose before above one with the same match.
    #[test]
    fn a_chat_chosen_before_ranks_first_among_equal_matches() {
        let entries = || {
            vec![
                rank_entry("codex:a", Some("Fix the build"), "New chat", None, "codex", None),
                rank_entry("codex:b", Some("Fix the build"), "New chat", None, "codex", None),
            ]
        };
        assert_eq!(ranked("fix build", entries(), None), vec![0, 1], "no history: the index order");
        let frecency: cmux_palette_ranker::Frecency = serde_json::from_value(json!({
            "entries": {"chat:codex:b": {"score": 3.0, "lastUsed": 990.0}}, "halfLife": 259_200.0
        }))
        .unwrap();
        assert_eq!(
            ranked("fix build", entries(), Some((1_000.0, frecency))),
            vec![1, 0],
            "the chosen chat first"
        );
    }

    #[test]
    fn a_query_window_reports_how_many_matched() {
        let mut state = WindowState::new(spec(json!({"window": "w", "query": "x"})), 0);
        let full = state
            .next(WindowRows { rows: vec![row("a:1", "one")], has_more: true, total: Some(250) })
            .unwrap();
        assert_eq!(full["total"], 250);
        let mut plain = WindowState::new(spec(json!({"window": "w"})), 0);
        assert!(plain.next(WindowRows::default()).unwrap().get("total").is_none());
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
        let first = WindowRows {
            rows: vec![row("a:1", "one"), row("a:2", "two")],
            has_more: true,
            total: None,
        };
        let full = state.next(first.clone()).unwrap();
        assert_eq!(full["full"], true);
        assert_eq!(full["revision"], 1);
        assert_eq!(full["gen"], 0);
        assert_eq!(full["rows"].as_array().unwrap().len(), 2);
        assert_eq!(state.next(first), None, "nothing new, nothing sent");
        let moved = WindowRows {
            rows: vec![row("a:2", "two"), row("a:1", "one, renamed")],
            has_more: true,
            total: None,
        };
        let diff = state.next(moved).unwrap();
        assert_eq!(diff["full"], false);
        assert_eq!(diff["revision"], 2);
        assert_eq!(diff["keys"], json!(["a:2", "a:1"]));
        assert_eq!(diff["rows"], json!([{"key": "a:1", "title": "one, renamed"}]));
        let more = WindowRows {
            rows: vec![row("a:2", "two"), row("a:1", "one, renamed")],
            has_more: false,
            total: None,
        };
        let diff = state.next(more).unwrap();
        assert_eq!(diff["rows"], json!([]), "only hasMore changed");
        assert_eq!(diff["hasMore"], false);
    }

    #[test]
    fn a_replaced_spec_sends_every_row_again_with_a_later_revision() {
        let mut state = WindowState::new(spec(json!({"window": "w"})), 0);
        state.next(WindowRows { rows: vec![row("a:1", "one")], has_more: false, total: None });
        let mut replaced =
            WindowState::new(spec(json!({"window": "w", "limit": 5})), state.revision());
        let full = replaced
            .next(WindowRows { rows: vec![row("a:1", "one")], has_more: false, total: None })
            .unwrap();
        assert_eq!(full["full"], true);
        assert_eq!(full["revision"], 2);
    }
}
