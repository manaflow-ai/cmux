//! `acpmux ls`'s flags, row filters (`--live`, `--host HOST`) and handler. A busy host lists
//! thousands of sessions, most of them closed, which no agent can read whole: with no filter the
//! text view is the compact one (`cli/ls_table.rs`), which counts what it hides and names the
//! flag that shows it. `--json` with no flag is the full list, unchanged: scripts (lane-place,
//! pr-owner and the reconcilers) read every row. The list is read in pages however large it is
//! (`ls_pages.rs`), and `--cursor` reads one. A listing never starts a daemon
//! (`daemon/running.rs`).

use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::ls_pages::{self, PAGE_ROWS, Plan, Step};
use crate::cli::errors;
use crate::cli::ls_table::{self, View};
use crate::cli::output::print_json;
use crate::cli::select::{self, parse_fields, project_fields, text_field};
use crate::daemon::connect_running;
use crate::rpc::method;

/// `acpmux ls`'s flags (`cli/command.rs` `Command::Ls`).
#[derive(clap::Args, Debug, Clone)]
pub struct LsArgs {
    /// Only sessions whose name matches one of these (a glob: `*`, `?`; `host/glob` for one
    /// peer's), or with this session id (bare, or a peer's `host/id`).
    #[arg(value_name = "PATTERN")]
    patterns: Vec<String>,
    /// The same as a PATTERN (repeatable): `--name 'review-*'`.
    #[arg(long = "name", value_name = "PATTERN")]
    name_patterns: Vec<String>,
    /// Include tool inventories in JSON rows (otherwise read `session info SESSION`); a peer's
    /// rows' are read from each session's peer.
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
    /// Return at most N sessions, newest first. With `--json`, `nextCursor` names where the
    /// next ones start (`--cursor`); null when none is left.
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u64).range(1..))]
    limit: Option<u64>,
    /// Read one page: the sessions after the `nextCursor` a paged `--json` listing printed
    /// (`--limit` of them, else 1000), and the page's own `nextCursor`. An empty one is the
    /// first page. A page may repeat the row the last one ended on, never skip one: a chat and
    /// its copy on a peer updated in the same millisecond share one cursor on older daemons, and
    /// a page of one past it holds two rows, as one row would hand that cursor back.
    #[arg(long, value_name = "CURSOR")]
    cursor: Option<String>,
    /// Select comma-separated fields from each session record; a dotted path reads a nested
    /// one (`turn.activity`, `lane.state`, `tags.area`).
    #[arg(long, value_name = "FIELD[,FIELD…]")]
    fields: Option<String>,
    /// Only sessions updated within this duration (for example `24h` or `30m`).
    #[arg(long, value_name = "DURATION")]
    since: Option<String>,
    /// Only live sessions: any status but closed.
    #[arg(long)]
    live: bool,
    /// Only sessions on this machine: its name, or this machine's (`local` too). `--host` still
    /// works.
    #[arg(long = "machine", alias = "host", value_name = "MACHINE")]
    host: Option<String>,
    /// Text view: also what the compact view hides (closed, reviewer, sub- and unnamed sessions).
    #[arg(long, short)]
    all: bool,
    /// Text view: every column (AGENT, STATUS, STUCK, the usage columns and LAST, the last
    /// prompt); the daemon reads each chat's usage first.
    #[arg(long, short)]
    wide: bool,
}

pub(super) async fn run(args: LsArgs, json_out: bool) -> Result<()> {
    let LsArgs {
        mut patterns,
        name_patterns,
        status,
        pending,
        tag,
        limit,
        cursor,
        fields,
        since,
        with_tools,
        live,
        host,
        all,
        wide,
    } = args;
    patterns.extend(name_patterns);
    let named = !patterns.is_empty();
    let since_ms = since.as_deref().map(parse_duration_ms).transpose()?;
    let selected = limit.is_some() || fields.is_some() || since_ms.is_some();
    let fields = fields.as_deref().map(parse_fields).transpose()?;
    let rows = RowFilter::new(live, host.as_deref(), crate::pairing::machine_name())?;
    // Any filter at all: the text view hides none of the rows it keeps (`ls_table.rs`).
    let filtered = rows.narrows()
        || status.is_some()
        || pending
        || tag.is_some()
        || selected
        || named
        || cursor.is_some();
    // A listing never starts a daemon (hq#4897 failure 4: an empty one on a dead socket read as
    // a host with no sessions).
    let client = connect_running().await?;
    // The text view says which peers are down; read alongside the list.
    let peers = (!json_out && fields.is_none()).then(|| {
        let client = client.clone();
        tokio::spawn(async move { client.request(method::MUX_STATUS, json!({})).await })
    });
    // The daemon drops what it can before it pages (`hub/session_pages.rs`): closed rows for
    // `--live`, other statuses for `--status`, peers' rows for `--host` this machine. One too
    // old for a filter sends the rows anyway, and `keeps` drops them below. A peer's name is
    // matched here only: `--host` takes it in any case, the daemon's `peer` in one.
    let mut params = json!({});
    if with_tools {
        params.set("withTools", json!(true));
    }
    // Only a listing that shows usage has the daemon read it first (`hub/usage_view.rs`); the
    // compact one shows the rows as they are. Every page asks; the daemon reads at most once
    // in 5 s, so the pages after the first take the rows that read left.
    let usage = shows_usage(wide, json_out, fields.as_deref());
    if usage {
        params.set("usage", json!(true));
    }
    if live {
        params.set("excludeStatus", json!(["closed"]));
    }
    let daemon_status = status.as_deref().filter(|s| !matches!(*s, "stuck" | "waiting"));
    if let Some(status) = daemon_status {
        params.set("status", json!(status));
    }
    if rows.local_only() {
        params.set("localOnly", json!(true));
    }
    let cutoff = since_ms.map(|duration| crate::store::now_ms().saturating_sub(duration));
    let keeps = |s: &Value| {
        let pend = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
        let st = s.get("status").and_then(Value::as_str).unwrap_or("");
        let status_ok = match status.as_deref() {
            None => true,
            Some("stuck") => s["state"] == "stuck",
            Some("waiting") => pend,
            Some(want) => st == want,
        };
        let tag_ok = tag.as_deref().is_none_or(|t| select::tag_matches(s, t));
        let name_ok = !named || select::name_matches(s, &patterns);
        status_ok && (!pending || pend) && tag_ok && name_ok && rows.keeps(s)
    };
    let step = |s: &Value| {
        // Newest first: a row older than `--since` ends the read.
        if cutoff.is_some_and(|at| s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0) < at) {
            Step::Stop
        } else if keeps(s) {
            Step::Keep
        } else {
            Step::Skip
        }
    };
    // `--cursor` reads one page (of `--limit` rows); `--limit` alone, the newest rows up to it;
    // neither, every page.
    let paged = cursor.is_some() || limit.is_some();
    let plan = Plan {
        size: cursor.is_some().then_some(limit).flatten().unwrap_or(PAGE_ROWS),
        want: if cursor.is_some() {
            None
        } else {
            limit.map(|n| usize::try_from(n).unwrap_or(usize::MAX))
        },
        one: cursor.is_some(),
        // A filter only this side applies thins the pages: asking for just the rows still
        // wanted could then take a request per row.
        exact: !named
            && tag.is_none()
            && !pending
            && (status.is_none() || daemon_status.is_some())
            && (host.is_none() || rows.local_only()),
    };
    let fetch = |page: Value| {
        let client = client.clone();
        async move { client.request(method::MUX_SESSIONS, page).await }
    };
    let read = ls_pages::read(params, cursor.filter(|c| !c.is_empty()), plan, step, fetch).await?;
    let mut sessions = read.rows;
    // A peer's row comes without its tools (`ls_tools.rs`): each is read from the peer, for
    // the views that print them.
    if with_tools && (json_out || fields.is_some()) {
        let unread = super::ls_tools::fill(&mut sessions, |key| {
            let client = client.clone();
            async move {
                let params = json!({"sessionId": key, "waitLogs": false});
                client.request(method::MUX_INFO, params).await
            }
        })
        .await;
        if unread > 0 {
            eprintln!(
                "acpmux: the tools of {unread} peer session(s) could not be read; they are listed without them"
            );
        }
    }
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
    if let Some(fields) = fields.as_deref() {
        sessions = sessions.into_iter().map(|s| project_fields(&s, fields)).collect();
    }
    let mut v = json!({"sessions": sessions});
    // A paged read hands on where the next rows start (null: none is left; absent: the whole
    // list of a daemon too old for pages, which takes no cursor).
    if let Some(next) = read.next.filter(|_| paged) {
        v.set("nextCursor", next);
    }
    if json_out {
        print_json(&v);
        return Ok(());
    }
    let sessions = match v.get_mut("sessions") {
        Some(Value::Array(rows)) => std::mem::take(rows),
        _ => Vec::new(),
    };
    if let Some(fields) = fields.as_deref() {
        println!("{}", fields.join("\t"));
        for session in sessions {
            println!(
                "{}",
                fields
                    .iter()
                    .map(|field| text_field(select::field(&session, field)))
                    .collect::<Vec<_>>()
                    .join("\t")
            );
        }
        return Ok(());
    }
    let peers = match peers {
        Some(read) => match read.await {
            Ok(Ok(status)) => status.get("peers").and_then(Value::as_array).cloned(),
            _ => None,
        },
        None => None,
    };
    let view = View { all, wide };
    let now = crate::store::now_ms();
    print!("{}", ls_table::render(&sessions, peers.as_deref(), view, filtered, now));
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

/// A projected listing reads usage only if that projection includes it.
fn shows_usage(wide: bool, json_out: bool, fields: Option<&[String]>) -> bool {
    match fields {
        Some(fields) => fields.iter().any(|f| f == "usageStats" || f.starts_with("usageStats.")),
        None => wide || json_out,
    }
}

/// The rows `--live` and `--host` keep.
pub(super) struct RowFilter {
    live: bool,
    host: Option<String>,
    /// This machine's name, which `--host` takes for a local row (as `local` too).
    own: String,
}

impl RowFilter {
    pub(super) fn new(live: bool, host: Option<&str>, own: String) -> Result<Self> {
        let host = host.map(str::trim).filter(|h| !h.is_empty()).map(str::to_ascii_lowercase);
        Ok(Self { live, host, own })
    }

    /// Whether either is set.
    pub(super) fn narrows(&self) -> bool {
        self.live || self.host.is_some()
    }

    /// `--host` names this machine: no peer's row is kept.
    pub(super) fn local_only(&self) -> bool {
        self.host.as_deref().is_some_and(|h| h == "local" || self.own.eq_ignore_ascii_case(h))
    }

    pub(super) fn keeps(&self, row: &Value) -> bool {
        (!self.live || is_live(row))
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

    fn kept(filter: &RowFilter) -> Vec<String> {
        rows()
            .iter()
            .filter(|r| filter.keeps(r))
            .map(|r| r["name"].as_str().unwrap().into())
            .collect()
    }

    #[test]
    fn projected_listings_only_refresh_usage_when_they_show_it() {
        let plain = vec!["sessionId".to_owned(), "name".to_owned(), "status".to_owned()];
        assert!(!shows_usage(false, true, Some(&plain)));
        assert!(!shows_usage(true, false, Some(&plain)));
        assert!(shows_usage(false, false, Some(&["usageStats.cost".to_owned()])));
        assert!(shows_usage(false, true, None));
        assert!(shows_usage(true, false, None));
        assert!(!shows_usage(false, false, None));
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
    fn live_and_host_filter_the_rows() {
        let own = || "this-mac".to_owned();
        let live = RowFilter::new(true, None, own()).unwrap();
        assert_eq!(kept(&live), ["claude-sr2/mac-ci-3", "hb/review-1", "idle-one"]);
        let peer = RowFilter::new(true, Some("HB"), own()).unwrap();
        assert_eq!(kept(&peer), ["hb/review-1"]);
        let here = RowFilter::new(false, Some("this-mac"), own()).unwrap();
        assert_eq!(kept(&here), ["claude-sr2/mac-ci-3", "done", "idle-one"]);
        let local = RowFilter::new(false, Some("local"), own()).unwrap();
        assert_eq!(kept(&local), kept(&here));
        assert!(!RowFilter::new(false, None, own()).unwrap().narrows());
        assert!(live.narrows() && peer.narrows());
    }
}
