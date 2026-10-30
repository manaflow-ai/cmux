//! `acpmux ls`'s row filters (`--live`, `--name REGEX`, `--host HOST`) and its compact text view.
//! A busy host lists thousands of sessions, most of them closed, which no agent can read whole:
//! with no filter the text view shows the live ones, newest first and at most [`COMPACT_ROWS`],
//! and says how many it left out and which flag shows them. `--json` with no flag is the full
//! list, unchanged: scripts (lane-place, pr-owner and the reconcilers) read every row.

use anyhow::Result;
use serde_json::{Value, json};

use crate::cli::errors::{self as errors, AppError};
use crate::cli::output::{age, print_json, short};
use crate::daemon::connect;
use crate::rpc::method;

/// `acpmux ls`'s flags (`cli/command.rs` `Command::Ls`).
#[derive(clap::Args, Debug, Clone)]
pub struct LsArgs {
    /// Include tool inventories in JSON rows (otherwise read `session info SESSION`).
    #[arg(long)]
    with_tools: bool,
    /// Only sessions in this state: running, ready, idle, closed, waiting.
    #[arg(long)]
    status: Option<String>,
    /// Only sessions with a pending permission request.
    #[arg(long)]
    pending: bool,
    /// Only sessions carrying this tag (key or key=value).
    #[arg(long)]
    tag: Option<String>,
    /// Return at most N sessions, newest first.
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u64).range(1..))]
    limit: Option<u64>,
    /// Select comma-separated fields from each session record.
    #[arg(long, value_name = "FIELD[,FIELD…]")]
    fields: Option<String>,
    /// Only sessions updated within this duration (for example `24h` or `30m`).
    #[arg(long, value_name = "DURATION")]
    since: Option<String>,
    /// Only live sessions: any status but closed.
    #[arg(long)]
    live: bool,
    /// Only sessions whose name (`HOST/NAME` for a peer's) matches this regular expression.
    #[arg(long, value_name = "REGEX")]
    name: Option<String>,
    /// Only sessions on this host: a peer's name, or this machine's (`local` too).
    #[arg(long, value_name = "HOST")]
    host: Option<String>,
    /// Text view: every session, closed ones too, instead of the compact live view.
    #[arg(long)]
    all: bool,
}

pub(super) async fn run(args: LsArgs, json_out: bool) -> Result<()> {
    let LsArgs { status, pending, tag, limit, fields, since, with_tools, live, name, host, all } =
        args;
    let since_ms = since.as_deref().map(parse_duration_ms).transpose()?;
    let selected = limit.is_some() || fields.is_some() || since_ms.is_some();
    let fields = fields.as_deref().map(parse_fields).transpose()?;
    let rows =
        RowFilter::new(live, name.as_deref(), host.as_deref(), crate::pairing::machine_name())?;
    // Any filter at all: the text view prints every row it keeps. None (and no
    // `--all`): the compact live view (`ls.rs`).
    let compact =
        !all && !rows.narrows() && status.is_none() && !pending && tag.is_none() && !selected;
    let client = connect(true).await?;
    // The daemon already sorts pages newest first. Ask it to trim the response when
    // possible; a `--since` filter must run before the limit, so that combination reads
    // the complete list and applies both filters locally.
    let daemon_limit =
        limit.filter(|_| status.is_none() && !pending && tag.is_none() && !rows.narrows());
    let mut params = if since_ms.is_none() {
        daemon_limit.map_or_else(|| json!({}), |n| json!({"limit": n}))
    } else {
        json!({})
    };
    if with_tools {
        params["withTools"] = json!(true);
    }
    // The daemon drops closed rows itself (`hub/session_pages.rs`), so a `--live` reply
    // carries none of them; `RowFilter` checks again below.
    if live {
        params["excludeStatus"] = json!(["closed"]);
    }
    let mut v = client.request(method::MUX_SESSIONS, params).await?;
    if status.is_some() || pending || tag.is_some() || selected || rows.narrows() {
        let mut sessions = match v.get_mut("sessions") {
            Some(Value::Array(rows)) => std::mem::take(rows),
            _ => Vec::new(),
        };
        if selected {
            sessions.sort_by(|a, b| {
                b.get("updatedAt")
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
                    .cmp(&a.get("updatedAt").and_then(Value::as_u64).unwrap_or(0))
                    .then_with(|| {
                        a.get("sessionId")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .cmp(b.get("sessionId").and_then(Value::as_str).unwrap_or(""))
                    })
            });
        }
        let cutoff = since_ms.map(|duration| crate::store::now_ms().saturating_sub(duration));
        sessions.retain(|s| {
            let pend = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
            let st = s.get("status").and_then(Value::as_str).unwrap_or("");
            let status_ok = match status.as_deref() {
                None => true,
                Some("stuck") => s["state"] == "stuck",
                Some("waiting") => pend,
                Some(want) => st == want,
            };
            let tag_ok = match tag.as_deref() {
                None => true,
                Some(t) => {
                    let (k, want) =
                        t.split_once('=').map(|(k, v)| (k, Some(v))).unwrap_or((t, None));
                    s.get("tags")
                        .and_then(|m| m.get(k))
                        .map(|v| {
                            want.map(|w| {
                                v.as_str() == Some(w)
                                    || v.get("value").and_then(Value::as_str) == Some(w)
                            })
                            .unwrap_or(true)
                        })
                        .unwrap_or(false)
                }
            };
            let since_ok = cutoff
                .is_none_or(|at| s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0) >= at);
            status_ok && (!pending || pend) && tag_ok && since_ok && rows.keeps(s)
        });
        if let Some(limit) = limit {
            sessions.truncate(usize::try_from(limit).unwrap_or(usize::MAX));
        }
        if let Some(fields) = fields.as_deref() {
            sessions = sessions.into_iter().map(|s| project_fields(&s, fields)).collect();
        }
        v["sessions"] = Value::Array(sessions);
    }
    if json_out {
        print_json(&v);
        return Ok(());
    }
    let sessions = match v.get_mut("sessions") {
        Some(Value::Array(rows)) => std::mem::take(rows),
        _ => Vec::new(),
    };
    if sessions.is_empty() {
        println!("no sessions (create one: acpmux new -m codex -n my-task)");
        return Ok(());
    }
    let (sessions, hidden) = text_rows(sessions, compact, COMPACT_ROWS);
    let note = hidden_note(&hidden, sessions.len());
    if let Some(fields) = fields.as_deref() {
        println!("{}", fields.join("\t"));
        for session in sessions {
            println!(
                "{}",
                fields
                    .iter()
                    .map(|field| text_field(session.get(field)))
                    .collect::<Vec<_>>()
                    .join("\t")
            );
        }
        return Ok(());
    }
    if sessions.is_empty() {
        println!("{}", note.unwrap_or_default());
        return Ok(());
    }
    println!("{:<24} {:<8} {:<13} {:>5} {:<6} LAST", "NAME", "AGENT", "STATUS", "TURNS", "AGE");
    for s in sessions {
        let g = |k: &str| s.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        let mut status = s["state"].as_str().map(str::to_owned).unwrap_or_else(|| g("status"));
        if s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0 {
            status = "waiting!".into();
        }
        println!(
            "{:<24} {:<8} {:<13} {:>5} {:<6} {}",
            short(&g("name"), 24),
            short(&g("harness"), 8),
            status,
            s.get("turnCount").and_then(Value::as_u64).unwrap_or(0),
            age(s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)),
            short(s.get("lastPrompt").and_then(Value::as_str).unwrap_or(""), 50)
        );
    }
    if let Some(note) = note {
        println!("{note}");
    }
    Ok(())
}

pub(super) fn parse_duration_ms(text: &str) -> Result<u64> {
    let mut rest = text.trim();
    let mut total = 0u64;
    if rest.is_empty() {
        return Err(
            errors::AppError::usage("--since requires a duration such as 30m or 24h").into()
        );
    }
    while !rest.is_empty() {
        let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if digits == 0 {
            return Err(errors::AppError::usage(format!(
                "invalid --since duration {text:?}; use values such as 30m or 24h"
            ))
            .into());
        }
        let (number_text, after_number) = rest.split_at_checked(digits).unwrap_or((rest, ""));
        let number: u64 = number_text.parse().map_err(|_| {
            errors::AppError::usage(format!(
                "invalid --since duration {text:?}; use values such as 30m or 24h"
            ))
        })?;
        rest = after_number;
        let unit_len = rest.chars().next().map_or(0, char::len_utf8);
        let unit = rest.get(..unit_len).unwrap_or("");
        let multiplier = match unit {
            "s" => 1_000,
            "m" => 60_000,
            "h" => 3_600_000,
            "d" => 86_400_000,
            "w" => 604_800_000,
            _ => {
                return Err(errors::AppError::usage(format!(
                    "invalid --since duration {text:?}; use values such as 30m or 24h"
                ))
                .into());
            }
        };
        total = total
            .checked_add(number.checked_mul(multiplier).ok_or_else(|| {
                errors::AppError::usage(format!("--since duration {text:?} is too large"))
            })?)
            .ok_or_else(|| {
                errors::AppError::usage(format!("--since duration {text:?} is too large"))
            })?;
        rest = rest.get(unit_len..).unwrap_or("");
    }
    Ok(total)
}

fn parse_fields(text: &str) -> Result<Vec<String>> {
    let fields: Vec<String> = text
        .split(',')
        .map(str::trim)
        .filter(|field| !field.is_empty())
        .map(str::to_owned)
        .collect();
    if fields.is_empty() {
        return Err(
            errors::AppError::usage("--fields requires a comma-separated field list").into()
        );
    }
    Ok(fields)
}

fn project_fields(session: &Value, fields: &[String]) -> Value {
    let mut row = serde_json::Map::new();
    for field in fields {
        if let Some(value) = session.get(field) {
            row.insert(field.clone(), value.clone());
        }
    }
    Value::Object(row)
}

fn text_field(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(value) => serde_json::to_string(value).unwrap_or_default(),
    }
}

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

/// The text view's rows. With `compact` (no filter and no `--all`), the live ones, newest first
/// as the daemon sent them, at most `cap`; otherwise every row in the daemon's order, as before.
pub(super) fn text_rows(rows: Vec<Value>, compact: bool, cap: usize) -> (Vec<Value>, Hidden) {
    if !compact {
        return (rows, Hidden::default());
    }
    let (mut live, closed): (Vec<Value>, Vec<Value>) = rows.into_iter().partition(is_live);
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
    fn ls_selection_parses_duration_and_projects_fields() {
        assert_eq!(parse_duration_ms("1h30m").unwrap(), 5_400_000);
        assert!(parse_duration_ms("oops").is_err());
        let fields = parse_fields("name, status").unwrap();
        assert_eq!(fields, ["name", "status"]);
        assert_eq!(
            project_fields(&json!({"name": "one", "status": "idle", "cwd": "/tmp"}), &fields),
            json!({"name": "one", "status": "idle"})
        );
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
        assert_eq!(names(&all), names(&rows()), "--all and any filter keep the daemon's order");
        assert_eq!(hidden_note(&none, all.len()), None);
        let closed_only = vec![json!({"name": "a", "status": "closed"})];
        let (shown, hidden) = text_rows(closed_only, true, 2);
        let note = hidden_note(&hidden, shown.len()).unwrap();
        assert!(note.starts_with("no live sessions; 1 closed not shown"), "{note}");
    }
}
