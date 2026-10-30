//! `acpmux ls`'s row filters (`--live`, `--name REGEX`, `--host HOST`) and its compact text view.
//! A busy host lists thousands of sessions, most of them closed, which no agent can read whole:
//! with no filter the text view shows the live ones, newest first and at most [`COMPACT_ROWS`],
//! and says how many it left out and which flag shows them. `--json` with no flag is the full
//! list, unchanged: scripts (lane-place, pr-owner and the reconcilers) read every row.

use anyhow::Result;
use serde_json::Value;

use crate::cli::errors::AppError;

/// The most rows the unfiltered text view prints.
pub(super) const COMPACT_ROWS: usize = 40;

/// The rows `--live`, `--name` and `--host` keep.
pub(super) struct RowFilter {
    live: bool,
    name: Option<regex::Regex>,
    host: Option<String>,
    /// This machine's name, which `--host` takes for a local row (as `local` too).
    own: String,
}

impl RowFilter {
    pub(super) fn new(
        live: bool,
        name: Option<&str>,
        host: Option<&str>,
        own: String,
    ) -> Result<Self> {
        let name = name
            .map(|pattern| {
                regex::Regex::new(pattern).map_err(|e| {
                    AppError::usage(format!("--name {pattern:?} is not a regular expression: {e}"))
                })
            })
            .transpose()?;
        let host = host.map(str::trim).filter(|h| !h.is_empty()).map(str::to_ascii_lowercase);
        Ok(Self { live, name, host, own })
    }

    /// Whether any of the three is set.
    pub(super) fn narrows(&self) -> bool {
        self.live || self.name.is_some() || self.host.is_some()
    }

    pub(super) fn keeps(&self, row: &Value) -> bool {
        (!self.live || is_live(row))
            && self.name.as_ref().is_none_or(|re| re.is_match(row["name"].as_str().unwrap_or("")))
            && self.host.as_deref().is_none_or(|want| {
                let host = row["peer"].as_str().filter(|p| !p.is_empty());
                match host {
                    Some(peer) => peer.eq_ignore_ascii_case(want),
                    None => want == "local" || self.own.eq_ignore_ascii_case(want),
                }
            })
    }
}

/// Whether a row is a live session: any status but closed.
pub(super) fn is_live(row: &Value) -> bool {
    row["status"].as_str() != Some("closed")
}

/// What the compact view left out.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Hidden {
    pub closed: usize,
    /// Live rows past [`COMPACT_ROWS`].
    pub live: usize,
}

/// The text view's rows: live before closed, each newest first as the daemon sent them. With
/// `compact` (no filter and no `--all`), closed rows go and at most `cap` live rows stay.
pub(super) fn text_rows(rows: Vec<Value>, compact: bool, cap: usize) -> (Vec<Value>, Hidden) {
    let (mut live, closed): (Vec<Value>, Vec<Value>) = rows.into_iter().partition(is_live);
    if !compact {
        live.extend(closed);
        return (live, Hidden::default());
    }
    let over = live.len().saturating_sub(cap);
    live.truncate(cap);
    (live, Hidden { closed: closed.len(), live: over })
}

/// The line under the compact view that says what it left out and how to see it.
pub(super) fn hidden_note(hidden: &Hidden, shown: usize) -> Option<String> {
    let mut parts = Vec::new();
    if hidden.live > 0 {
        parts.push(format!("{} more live", hidden.live));
    }
    if hidden.closed > 0 {
        parts.push(format!("{} closed", hidden.closed));
    }
    if parts.is_empty() {
        return None;
    }
    let what = if shown == 0 { "no live sessions; " } else { "" };
    Some(format!(
        "{what}{} not shown: --all lists every session; --live, --name REGEX, --host HOST, \
--status S or --limit N narrow it",
        parts.join(" and ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rows() -> Vec<Value> {
        vec![
            json!({"name": "hb/old", "peer": "hb", "status": "closed"}),
            json!({"name": "claude-sr2/mac-ci-3", "status": "running"}),
            json!({"name": "hb/review-1", "peer": "hb", "status": "ready"}),
            json!({"name": "done", "status": "closed"}),
            json!({"name": "idle-one", "status": "idle"}),
        ]
    }

    fn names(rows: &[Value]) -> Vec<&str> {
        rows.iter().map(|r| r["name"].as_str().unwrap()).collect()
    }

    fn kept(filter: &RowFilter) -> Vec<String> {
        rows()
            .iter()
            .filter(|r| filter.keeps(r))
            .map(|r| r["name"].as_str().unwrap().into())
            .collect()
    }

    #[test]
    fn live_name_and_host_filter_the_rows() {
        let own = || "big-red".to_owned();
        let live = RowFilter::new(true, None, None, own()).unwrap();
        assert_eq!(kept(&live), ["claude-sr2/mac-ci-3", "hb/review-1", "idle-one"]);
        let name = RowFilter::new(false, Some("^hb/|mac-ci"), None, own()).unwrap();
        assert_eq!(kept(&name), ["hb/old", "claude-sr2/mac-ci-3", "hb/review-1"]);
        let peer = RowFilter::new(true, None, Some("HB"), own()).unwrap();
        assert_eq!(kept(&peer), ["hb/review-1"]);
        let here = RowFilter::new(false, None, Some("big-red"), own()).unwrap();
        assert_eq!(kept(&here), ["claude-sr2/mac-ci-3", "done", "idle-one"]);
        let local = RowFilter::new(false, None, Some("local"), own()).unwrap();
        assert_eq!(kept(&local), kept(&here));
        assert!(!RowFilter::new(false, None, None, own()).unwrap().narrows());
        assert!(live.narrows() && name.narrows() && peer.narrows());
    }

    #[test]
    fn a_bad_name_pattern_is_a_usage_error() {
        let Err(e) = RowFilter::new(false, Some("("), None, String::new()) else {
            panic!("accepted")
        };
        let app = e.downcast_ref::<AppError>().unwrap();
        assert_eq!(app.code, crate::cli::errors::Code::Usage);
        assert!(app.message.contains("--name \"(\""), "{}", app.message);
    }

    /// The compact view: live rows first and capped, closed ones counted, with the flag that
    /// shows them; `--all` (not compact) keeps every row, live first.
    #[test]
    fn the_compact_view_shows_live_rows_and_says_what_it_hid() {
        let (shown, hidden) = text_rows(rows(), true, 2);
        assert_eq!(names(&shown), ["claude-sr2/mac-ci-3", "hb/review-1"]);
        assert_eq!(hidden, Hidden { closed: 2, live: 1 });
        let note = hidden_note(&hidden, shown.len()).unwrap();
        assert!(note.starts_with("1 more live and 2 closed not shown: --all"), "{note}");
        let (all, none) = text_rows(rows(), false, 2);
        assert_eq!(
            names(&all),
            ["claude-sr2/mac-ci-3", "hb/review-1", "idle-one", "hb/old", "done"]
        );
        assert_eq!(hidden_note(&none, all.len()), None);
        let closed_only = vec![json!({"name": "a", "status": "closed"})];
        let (shown, hidden) = text_rows(closed_only, true, 2);
        let note = hidden_note(&hidden, shown.len()).unwrap();
        assert!(note.starts_with("no live sessions; 1 closed not shown"), "{note}");
    }
}
