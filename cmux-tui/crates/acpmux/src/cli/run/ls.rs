//! `acpmux ls`'s flags, row filters (`--live`, `--host HOST`) and handler. A busy host lists
//! thousands of sessions, most of them closed, which no agent can read whole: with no filter the
//! text view is the compact one (`cli/ls_table.rs`), which counts what it hides and names the
//! flag that shows it. `--json` with no flag is the full list, unchanged: scripts (lane-place,
//! pr-owner and the reconcilers) read every row. A listing never starts a daemon
//! (`daemon/running.rs`).

use anyhow::Result;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

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
    /// Only sessions on this host: a peer's name, or this machine's (`local` too).
    #[arg(long, value_name = "HOST")]
    host: Option<String>,
    /// Text view: also what the compact view hides (closed, reviewer, sub- and unnamed sessions).
    #[arg(long, short)]
    all: bool,
    /// Text view: every column (AGENT, STATUS, STUCK and LAST, the last prompt).
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
    let filtered =
        rows.narrows() || status.is_some() || pending || tag.is_some() || selected || named;
    // A listing never starts a daemon (hq#4897 failure 4: an empty one on a dead socket read as
    // a host with no sessions).
    let client = connect_running().await?;
    // The text view says which peers are down; read alongside the list.
    let peers = (!json_out && fields.is_none()).then(|| {
        let client = client.clone();
        tokio::spawn(async move { client.request(method::MUX_STATUS, json!({})).await })
    });
    // The daemon already sorts pages newest first. Ask it to trim the response when
    // possible; a `--since` filter must run before the limit, so that combination reads
    // the complete list and applies both filters locally.
    let daemon_limit = limit
        .filter(|_| status.is_none() && !pending && tag.is_none() && !rows.narrows() && !named);
    let mut params = if since_ms.is_none() {
        daemon_limit.map_or_else(|| json!({}), |n| json!({"limit": n}))
    } else {
        json!({})
    };
    if with_tools {
        params.set("withTools", json!(true));
    }
    // The daemon drops closed rows itself (`hub/session_pages.rs`), so a `--live` reply
    // carries none of them; `RowFilter` checks again below.
    if live {
        params.set("excludeStatus", json!(["closed"]));
    }
    let mut v = client.request(method::MUX_SESSIONS, params).await?;
    if status.is_some() || pending || tag.is_some() || selected || rows.narrows() || named {
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
            let tag_ok = tag.as_deref().is_none_or(|t| select::tag_matches(s, t));
            let name_ok = !named || select::name_matches(s, &patterns);
            let since_ok = cutoff
                .is_none_or(|at| s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0) >= at);
            status_ok && (!pending || pend) && tag_ok && name_ok && since_ok && rows.keeps(s)
        });
        if let Some(limit) = limit {
            sessions.truncate(usize::try_from(limit).unwrap_or(usize::MAX));
        }
        if let Some(fields) = fields.as_deref() {
            sessions = sessions.into_iter().map(|s| project_fields(&s, fields)).collect();
        }
        v.set("sessions", Value::Array(sessions));
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
