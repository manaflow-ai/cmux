//! `sendRelay` (config.json): the command `acpmux send` hands a message to when its target names
//! no session here and no peer lists it.
//!
//! Some hosts have no peer that reaches the target: an agent VM that cannot dial back to the
//! machine that drives it. A relay command, e.g. one that hands the message to a broker the
//! driving machine keeps a connection to, still delivers it there. With
//! `"sendRelay": {"argv": ["relay", "send"]}` the CLI runs `relay send SESSION -` with the
//! message on stdin and `ACPMUX_FROM` set to the sender it would have named, prints the
//! command's stdout (its delivery id) and exits with its status. A Claude Code subagent's send
//! also sets `ACPMUX_FROM_SUBAGENT` (`TYPE:ID`) and `ACPMUX_FROM_LABEL` (`LEAD's TYPE subagent
//! ID`), labels for the relay to show; `ACPMUX_FROM` stays the lead's name, the one reply address
//! the relay has, so the far side's answer reaches the lead (W5-M (b), 2026-11-09).
//!
//! An explicit message class is passed as `ACPMUX_SEND_CLASS` (canonical `block`, `question`,
//! `result` or `fyi`); without one, that variable is removed. The argv remains `SESSION -`
//! for existing relay commands. A relay that understands classes forwards this metadata.
//!
//! Only the no-session refusal relays: a target here or on a peer, down or not, is sent as
//! always, and with no `sendRelay` nothing changes. The relay carries text only, so a send with
//! `--attach` is refused rather than relayed without its files. The MCP `send` tool relays the
//! same way (`acpmux_mcp_send.rs`), and every relayed send is a line in the cross-host audit log
//! (`xhost_audit.rs`).
//!
//! `"lsArgv": ["relay", "sessions"]` is how such a host sees the other machines' sessions: `acpmux
//! ls` (and the MCP `ls` tool) runs it, reads `{"sessions": [...]}` from its stdout, and lists every
//! row whose `peer` names another machine beside this host's own, so `HOST/NAME` is found before
//! it is sent to. A relay that fails or is slow costs a warning, never the local list: `ls`
//! waits for it a short budget and otherwise serves its last good listing (`ls_far.rs`).
//! Leo, 2026-11-05, on sends between lane machines: "Just do what's expected. Just do the magic."

use crate::cli::errors::{AppError, Code};
use crate::cli::output::print_json;
use crate::cli::sender::{FROM_ENV, Subagent};
use crate::prompt_class::PromptClass;
use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};
use tokio::time::Instant;

pub use crate::config::SendRelay;

/// How long a relay listing may take before `ls` goes on without it. Shorter than the `ls` it
/// runs inside (`cli/run/ls.rs` `LS_TOTAL_DEADLINE`, asserted there), so a slow relay ends as
/// "the relay listing" timing out, not as the whole `ls` stalling (RFD 0050 rule 5).
pub(crate) const LS_DEADLINE: std::time::Duration = std::time::Duration::from_secs(12);

/// The directories under `$HOME` a relay program is looked for in when it is a bare name the
/// PATH lacks, as `native.rs` looks for `opencode`: `lane-gh` lives in `~/.local/bin`, on a
/// lane VM shell's PATH but not the acpmux daemon's, so every MCP `send` to a peer reached through
/// the broker failed `cannot run the send relay "lane-gh": No such file or directory`
/// (2026-11-21).
const HOME_BIN_DIRS: [&str; 3] = [".local/bin", ".bun/bin", "bin"];

/// The well-known install directories outside `$HOME`, after those.
const SYSTEM_BIN_DIRS: [&str; 2] = ["/opt/homebrew/bin", "/usr/local/bin"];

/// The program a relay's `argv[0]` runs: a path as it is; a bare name on `path` (the daemon's
/// own, then the login PATH spawned processes see), else under `home`'s and the system's
/// install directories, as an absolute path. A miss names every place it looked.
pub(crate) fn relay_program(
    program: &str,
    paths: &[std::ffi::OsString],
    home: Option<&std::path::Path>,
) -> Result<std::path::PathBuf> {
    if program.contains('/') {
        return Ok(program.into());
    }
    let mut tried: Vec<std::path::PathBuf> = Vec::new();
    let dirs = paths
        .iter()
        .flat_map(std::env::split_paths)
        .chain(home.into_iter().flat_map(|h| HOME_BIN_DIRS.map(|d| h.join(d))))
        .chain(SYSTEM_BIN_DIRS.map(std::path::PathBuf::from));
    for dir in dirs {
        if dir.as_os_str().is_empty() || tried.contains(&dir) {
            continue;
        }
        let candidate = dir.join(program);
        if crate::harness_install::is_executable(&candidate) {
            return Ok(candidate);
        }
        tried.push(dir);
    }
    let shown: Vec<String> = tried.iter().map(|d| d.join(program).display().to_string()).collect();
    Err(anyhow!("cannot find the send relay {program:?}: tried {}", shown.join(", ")))
}

/// [`relay_program`] with this process's PATH, the login PATH and `$HOME`.
pub(crate) fn find_relay_program(program: &str) -> Result<std::path::PathBuf> {
    let paths: Vec<std::ffi::OsString> =
        std::env::var_os("PATH").into_iter().chain(crate::login_env::path()).collect();
    relay_program(program, &paths, dirs::home_dir().as_deref())
}

/// The other machines' sessions the relay's `lsArgv` lists: rows whose `peer` is a machine name
/// other than this one's, at most `LS_MAX_ROWS`. `Ok(None)` when no `lsArgv` is configured.
pub(crate) fn relay_ls(relay: &SendRelay, deadline: Option<Instant>) -> Result<Option<Vec<Value>>> {
    let Some((program, args)) = relay.ls_argv.as_deref().and_then(<[String]>::split_first) else {
        return Ok(None);
    };
    let mut cmd = Command::new(find_relay_program(program)?);
    cmd.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let child = cmd.spawn().with_context(|| format!("cannot run the relay listing {program:?}"))?;
    let deadline = deadline.unwrap_or_else(|| Instant::now() + LS_DEADLINE);
    let done = crate::cli::bounded_child::wait(child, None, Some(deadline), "the relay listing")
        .map_err(|e| anyhow!("the relay listing {program:?}: {e}"))?;
    if !done.status.success() {
        return Err(anyhow!(
            "the relay listing {program:?} exited {}",
            done.status.code().unwrap_or(1)
        ));
    }
    let value: Value = serde_json::from_slice(&done.stdout)
        .with_context(|| format!("the relay listing {program:?} printed no JSON"))?;
    let own = crate::pairing::machine_name();
    let rows = value
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("the relay listing {program:?} printed no sessions list"))?;
    Ok(Some(
        rows.iter()
            .filter(|r| {
                r.get("peer")
                    .and_then(Value::as_str)
                    .is_some_and(|p| !p.is_empty() && p != "local" && !p.eq_ignore_ascii_case(&own))
                    && r.get("sessionId").and_then(Value::as_str).is_some()
            })
            .take(LS_MAX_ROWS)
            .cloned()
            .map(|mut row| {
                // How the row is reached: through the relay that listed it, not this daemon.
                if let Some(fields) = row.as_object_mut() {
                    fields.insert("via".to_owned(), json!(VIA));
                    given_handle(fields);
                }
                row
            })
            .collect(),
    ))
}

/// A relay row's given handle as `handle`, the key `ls`, `resolve` and `send` read
/// ([`find_row`], `session_handle::matches`). A relay may carry it as `displayName` alone (the
/// given handle only, `SessionSummary::display_name`) so a derived handle stays off its wire;
/// without this, a renamed chat on another machine was found only by its older name (Leo,
/// 2026-11-23: "the send/recieve messages are still only the older names").
pub(crate) fn given_handle(row: &mut serde_json::Map<String, Value>) {
    let valid = |v: Option<&Value>| {
        v.and_then(Value::as_str).filter(|h| crate::session_handle::valid(h)).map(str::to_owned)
    };
    if valid(row.get("handle")).is_some() {
        return;
    }
    if let Some(given) = valid(row.get("displayName")) {
        row.insert("handle".to_owned(), Value::String(given));
    }
}

/// The `via` of a row the relay lists: no peer link or hub of this daemon reaches it, so only
/// the relay's own verbs do (`send` through `argv`, its row through `lsArgv`).
pub(crate) const VIA: &str = "relay";

/// How long a lookup of one key in the relay's listing may take (`listed_row`).
const LOOKUP_DEADLINE: std::time::Duration = std::time::Duration::from_secs(5);

/// The one row of `rows` that `key` names: `HOST/NAME`, `HOST/ID`, the qualified id, the bare
/// id, or a bare name only one row carries (the relay may list a name with its host's prefix).
pub(crate) fn find_row<'a>(rows: &'a [Value], key: &str) -> Option<&'a Value> {
    let text = |r: &'a Value, k: &str| r.get(k).and_then(Value::as_str).unwrap_or_default();
    let named = |r: &'a Value| {
        let (peer, id, name) = (text(r, "peer"), text(r, "sessionId"), text(r, "name"));
        let bare = name.strip_prefix(peer).and_then(|n| n.strip_prefix('/')).unwrap_or(name);
        let on_peer = |rest: &str| {
            !rest.is_empty()
                && key.strip_prefix(peer).and_then(|k| k.strip_prefix('/')) == Some(rest)
        };
        key == id
            || key == text(r, "qualifiedSessionId")
            || on_peer(id)
            || on_peer(bare)
            || (!bare.is_empty() && (key == bare || key == name))
            || crate::session_handle::matches(r["handle"].as_str(), id, key)
            || key
                .strip_prefix(peer)
                .and_then(|rest| rest.strip_prefix('/'))
                .is_some_and(|rest| crate::session_handle::matches(r["handle"].as_str(), id, rest))
    };
    let mut found = rows.iter().filter(|&r| named(r));
    let first = found.next()?;
    found.next().is_none().then_some(first)
}

/// What the configured relay's listing says about one key ([`listed_row`]).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Lookup {
    /// The relay lists one row for the key: read now, or from its kept listing.
    Listed(Value),
    /// The relay answered and lists no one row for the key (or no relay lists at all).
    NotListed,
    /// The relay's listing failed or ran past its deadline, and its kept listing has no row for
    /// the key: whether it lists one is unknown (RFD 0050 rule 2: a miss on the relay is never
    /// a verdict on the session). The text says why.
    Unknown(String),
}

/// What the configured relay's listing says about `key` ([`find_row`]). Asked only once this
/// daemon found no session for `key`.
///
/// The kept listing (`ls_far.rs`'s cache, the one `ls` serves) is read first: a row it has is
/// the answer at once, whatever the relay's state (rule 4, last-known-good). Otherwise the relay
/// is read within [`LOOKUP_DEADLINE`], unless it missed before and has not answered since (the
/// mark `ls` leaves): then it is not waited on again. A read that fails or runs out is
/// [`Lookup::Unknown`], never [`Lookup::NotListed`]: a slow relay is not "no such session".
pub(crate) async fn listed_row(key: &str) -> Lookup {
    let Some(relay) = configured().filter(|r| r.ls_argv.is_some()) else {
        return Lookup::NotListed;
    };
    let cache = crate::cli::ls_far::cache_file();
    let key = key.to_owned();
    let source = relay.ls_argv.as_deref().and_then(<[String]>::first).map_or_else(
        || VIA.to_owned(),
        |p| Path::new(p).file_name().map_or(p.clone(), |n| n.to_string_lossy().into_owned()),
    );
    tokio::task::spawn_blocking(move || {
        lookup(&key, &cache, &source, crate::store::now_ms(), || {
            relay_ls(&relay, Some(Instant::now() + LOOKUP_DEADLINE))
        })
    })
    .await
    .unwrap_or_else(|e| Lookup::Unknown(format!("the relay lookup stopped: {e}")))
}

/// [`listed_row`] with the kept listing's path, the time and the relay read given (tests).
pub(crate) fn lookup(
    key: &str,
    cache: &Path,
    source: &str,
    now: u64,
    read: impl FnOnce() -> Result<Option<Vec<Value>>>,
) -> Lookup {
    let kept = crate::cli::ls_far::read_cache(cache, now);
    if let Some(row) = kept.as_ref().and_then(|(_, rows)| find_row(rows, key)) {
        return Lookup::Listed(row.clone());
    }
    if crate::cli::ls_far::missed_mark_live(cache, now) {
        return Lookup::Unknown(format!(
            "the send relay's listing has not answered since it last missed ({})",
            crate::cli::ls_far::NO_ANSWER_YET
        ));
    }
    match read() {
        Ok(None) => Lookup::NotListed,
        Ok(Some(rows)) => {
            crate::cli::ls_far::write_cache(cache, source, &rows, now);
            find_row(&rows, key).cloned().map_or(Lookup::NotListed, Lookup::Listed)
        }
        Err(e) => Lookup::Unknown(format!("the send relay's listing did not answer: {e:#}")),
    }
}

/// The daemon's no-session refusal for `key` (`e`) when the relay's listing could not say
/// whether it lists `key`: still the refusal a send relays on ([`no_such_session`]), so a send
/// is handed to the relay as before, but it no longer claims there is no such session. It says
/// the relay was not read, why, and `data.relayListing` is `unknown` for a program.
pub(crate) fn unknown_refusal(key: &str, e: anyhow::Error, why: &str) -> anyhow::Error {
    let Some(app) = e.downcast_ref::<AppError>() else { return e };
    let mut app = app.clone();
    app.message = format!(
        "no session matches {key:?} here or on a peer, and whether the send relay lists it is unknown: {why}; `{} send {key} MESSAGE` still hands it to the relay",
        crate::cli::entry::program()
    );
    app.retryable = true;
    let mut data = app.data.take().unwrap_or_else(|| json!({}));
    if let Some(fields) = data.as_object_mut() {
        fields.insert("relayListing".into(), json!({"state": "unknown", "reason": why}));
    }
    app.data = Some(data);
    app.into()
}

/// The no-session refusal for `key`, which only the relay lists as `row`: still the refusal a
/// send relays on ([`no_such_session`]), saying what reaches the row, with the row in its data
/// ([`relayed_row`]), so `info` answers with the row as the relay listed it.
pub(crate) fn listed_refusal(key: &str, row: Value) -> AppError {
    let text = |k: &str| row.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let (peer, name) = (text("peer"), text("name"));
    let bare =
        name.strip_prefix(peer.as_str()).and_then(|n| n.strip_prefix('/')).unwrap_or(name.as_str());
    let target = if bare.is_empty() {
        format!("{peer}/{}", text("sessionId"))
    } else {
        format!("{peer}/{bare}")
    };
    AppError::new(
        Code::NoSession,
        "no_session",
        format!(
            "{key:?} is {target}, which only the send relay lists (sendRelay.lsArgv): this daemon has no link to read or attach to it; prompt it with `{} send {target} MESSAGE`, which the send relay delivers",
            crate::cli::entry::program()
        ),
    )
    .with_data(json!({"via": VIA, "target": target, "row": row}))
}

/// The relay's row a [`listed_refusal`] carries.
pub(crate) fn relayed_row(e: &anyhow::Error) -> Option<&Value> {
    let data = e.downcast_ref::<AppError>()?.data.as_ref()?;
    if data.get("via").and_then(Value::as_str) == Some(VIA) { data.get("row") } else { None }
}

/// At most this many rows from one relay listing.
pub(crate) const LS_MAX_ROWS: usize = 5000;

/// `rows` (this daemon's list) with `far` (the relay's) added, none twice: a peer row this
/// daemon lists already, by its machine and session id. How many were added.
pub(crate) fn merge_rows(rows: &mut Vec<Value>, far: Vec<Value>) -> usize {
    let key = |r: &Value| {
        (
            r.get("peer").and_then(Value::as_str).unwrap_or_default().to_owned(),
            r.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned(),
        )
    };
    let mut seen: std::collections::HashSet<_> = rows.iter().map(key).collect();
    let before = rows.len();
    rows.extend(far.into_iter().filter(|r| seen.insert(key(r))));
    rows.len() - before
}

/// The relay config.json names, if any. Read on its own: a send loads no profiles.
pub(crate) fn configured() -> Option<SendRelay> {
    configured_in(&crate::config::Config::path())
}

fn configured_in(path: &Path) -> Option<SendRelay> {
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let relay = value.get("sendRelay").filter(|v| !v.is_null())?;
    match serde_json::from_value::<SendRelay>(relay.clone()) {
        Ok(relay) if relay.argv.first().is_some_and(|p| !p.trim().is_empty()) => Some(relay),
        Ok(_) => {
            eprintln!("acpmux: sendRelay in {} has no argv; not relaying", path.display());
            None
        }
        Err(e) => {
            eprintln!(
                "acpmux: sendRelay in {} is not {{\"argv\": [...]}} ({e}); not relaying",
                path.display()
            );
            None
        }
    }
}

/// The send was refused because its target names no session here and no peer lists it: the
/// CLI's own no-session error (`run.rs` `resolve_id`, `send_async.rs` `queue`), never a
/// delivery's later failure or `@` outside a session.
pub(crate) fn no_such_session(e: &anyhow::Error) -> bool {
    e.downcast_ref::<AppError>()
        .is_some_and(|a| a.code == Code::NoSession && a.detail == "no_session")
}

/// Uploading `--attach` files that do not fit one message first asks the daemon about the
/// target: with a relay configured, its "no session" answer is the no-session refusal, so the
/// send says the relay carries text only instead of a bare daemon error.
pub(crate) fn attach_error(e: anyhow::Error, relaying: bool, session: &str) -> anyhow::Error {
    let unknown = relaying
        && e.downcast_ref::<crate::client::DaemonError>().is_some()
        && e.to_string().to_lowercase().contains("no session");
    if unknown { AppError::no_session(session).into() } else { e }
}

/// The sender the relay names in `ACPMUX_FROM`: `--from` or `ACPMUX_FROM` outside a session
/// (`named`), else `ACPMUX_FROM`, else the acpmux session this runs in, which its own daemon
/// would have proved; the relay's receiver has no daemon to prove it to.
pub(crate) fn sender(named: Option<&str>, env: impl Fn(&str) -> Option<String>) -> Option<String> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    named
        .map(str::to_owned)
        .or_else(|| set(FROM_ENV))
        .or_else(|| set("ACPMUX_SESSION_ID").and_then(|_| set("ACPMUX_SESSION_NAME")))
}

/// The env a relay gets with the subagent that sent the message (`TYPE:ID`), beside
/// `ACPMUX_FROM`: a label within the session that sent it, never a reply address.
pub(crate) const FROM_SUBAGENT_ENV: &str = "ACPMUX_FROM_SUBAGENT";
/// The env a relay gets with who sent the message, for a person to read:
/// `LEAD's TYPE subagent ID` for a subagent's send.
pub(crate) const FROM_LABEL_ENV: &str = "ACPMUX_FROM_LABEL";

/// At most this many bytes of the sender's name go in `ACPMUX_FROM_LABEL`.
const LABEL_NAME_BYTES: usize = 64;

/// A character the label leaves out of a sender's name: a control character, a Unicode line or
/// paragraph separator (U+2028, U+2029), or a bidi control or mark (U+202A-U+202E,
/// U+2066-U+2069, U+200E, U+200F, U+061C).
fn hidden_in_a_label(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{061C}'
                | '\u{200E}'
                | '\u{200F}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202A}'..='\u{202E}'
                | '\u{2066}'..='\u{2069}'
        )
}

/// A relayed send's explicit class and sender metadata. `name` is the relay's `ACPMUX_FROM`
/// (the sender's session, where the far side's answer goes); `subagent` names the Claude Code
/// subagent that sent it (`cli::sender::SUBAGENT_ENV`, or the MCP call's tool use id).
#[derive(Debug, Default, Clone, PartialEq)]
pub(crate) struct RelayMetadata {
    pub name: Option<String>,
    pub subagent: Option<Subagent>,
    pub class: Option<PromptClass>,
}

impl RelayMetadata {
    /// `name`'s send, by the subagent `sub` (`{id, type}`, plain words) when one is given.
    pub(crate) fn new(
        name: Option<String>,
        sub: Option<&Value>,
        class: Option<PromptClass>,
    ) -> Self {
        let subagent = sub.and_then(|sub| {
            let word = |key: &str| {
                sub.get(key)
                    .and_then(Value::as_str)
                    .filter(|w| crate::cli::sender::subagent_word(w))
                    .map(str::to_owned)
            };
            Some(Subagent { kind: word("type")?, id: word("id")? })
        });
        Self { name, subagent, class }
    }

    /// `ACPMUX_FROM_LABEL`: "lane's general-purpose subagent a0a68e7a". The name comes from
    /// `--from`, `ACPMUX_FROM` or the session's name, which the sender chose: only its first
    /// [`LABEL_NAME_BYTES`] bytes go in, with no character that breaks or reorders a line
    /// ([`hidden_in_a_label`]), so it cannot add a line or hide text.
    fn label(&self) -> Option<String> {
        let sub = self.subagent.as_ref()?;
        let name = self.name.as_deref().map(|name| {
            let mut plain = String::new();
            for c in name.chars().filter(|&c| !hidden_in_a_label(c)) {
                if plain.len() + c.len_utf8() > LABEL_NAME_BYTES {
                    break;
                }
                plain.push(c);
            }
            plain.trim().to_owned()
        });
        Some(match name.filter(|name| !name.is_empty()) {
            Some(name) => format!("{name}'s {}", sub.label()),
            None => sub.label(),
        })
    }
}

/// The cross-host audit line of one relayed send (`xhost_audit.rs`), never its text: `sent`
/// when the relay took it, `refused` when it exited non-zero (nothing crossed machines).
pub(crate) fn audit_sent(session: &str, text: &str, from: &RelayMetadata, done: &Relayed) {
    let sub = from.subagent.as_ref().map(Subagent::to_value);
    crate::xhost_audit::record(
        if done.status == 0 { "sent" } else { "refused" },
        json!({"via": "sendRelay", "to": session, "from": from.name, "fromSubagent": sub,
               "bytes": text.len(), "exit": done.status,
               "delivery": delivery_id(done.output.as_deref())}),
    );
}

/// The delivery id a relay's JSON answer names (`deliveryId`, at the top or under `data`), when
/// it is a short plain token: the audit log keeps that and nothing else of the relay's output,
/// which may carry the message.
fn delivery_id(output: Option<&str>) -> Option<String> {
    let answer: Value = serde_json::from_str(output?.trim()).ok()?;
    let id = answer
        .get("deliveryId")
        .or_else(|| answer.pointer("/data/deliveryId"))
        .or_else(|| answer.pointer("/data/delivery"))
        .and_then(Value::as_str)?;
    (!id.is_empty()
        && id.len() <= 128
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':')))
    .then(|| id.to_owned())
}

/// What the relay did.
#[derive(Debug, PartialEq)]
pub(crate) struct Relayed {
    /// Its exit status (1 when a signal ended it).
    pub status: i32,
    /// Its stdout, when captured (`--json`).
    pub output: Option<String>,
    /// Its stderr, when captured (with stdout): a refusal's reason, for a caller with no
    /// terminal of its own (the MCP `send` tool) or to print it after the JSON.
    pub stderr: Option<String>,
}

/// Run a relay while respecting the caller's absolute deadline. The child is
/// put in its own process group so expiry can only terminate this command and
/// any descendants it started.
pub(crate) fn relay_with_deadline(
    relay: &SendRelay,
    session: &str,
    text: &str,
    from: &RelayMetadata,
    capture: bool,
    deadline: Option<Instant>,
) -> Result<Relayed> {
    let (program, args) =
        relay.argv.split_first().ok_or_else(|| anyhow!("sendRelay has no argv"))?;
    let mut cmd = Command::new(find_relay_program(program)?);
    cmd.args(args)
        .arg(session)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(if capture { Stdio::piped() } else { Stdio::inherit() })
        .stderr(if capture { Stdio::piped() } else { Stdio::inherit() });
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    match &from.name {
        Some(from) => cmd.env(FROM_ENV, from),
        None => cmd.env_remove(FROM_ENV),
    };
    // Labels only, set or removed so an inherited value never names another sender.
    match (&from.subagent, from.label()) {
        (Some(sub), Some(label)) => cmd
            .env(FROM_SUBAGENT_ENV, format!("{}:{}", sub.kind, sub.id))
            .env(FROM_LABEL_ENV, label),
        _ => cmd.env_remove(FROM_SUBAGENT_ENV).env_remove(FROM_LABEL_ENV),
    };
    // Per-message metadata must never inherit a previous relay's class.
    match from.class {
        Some(class) => cmd.env("ACPMUX_SEND_CLASS", class.as_str()),
        None => cmd.env_remove("ACPMUX_SEND_CLASS"),
    };
    let child = cmd.spawn().with_context(|| format!("cannot run the send relay {program:?}"))?;
    // Written beside the wait, so a relay that answers before reading it all never blocks us.
    let done = crate::cli::bounded_child::wait(
        child,
        Some(text.as_bytes().to_owned()),
        deadline,
        "the send relay",
    )
    .map_err(|e| -> anyhow::Error {
        if e.kind() == std::io::ErrorKind::TimedOut {
            AppError::timeout(format!(
                "the send relay for {session:?} exceeded its caller deadline"
            ))
            .into()
        } else {
            anyhow::Error::new(e).context("the send relay")
        }
    })?;
    let (status, output, stderr) = (done.status, done.stdout, done.stderr);
    let written = done.written.unwrap_or_else(|| Err(std::io::Error::other("no stdin")));
    let status = status.code().unwrap_or(1);
    // A relay that stopped reading and still said yes was not handed the whole message; its own
    // refusal stays its status.
    if status == 0
        && let Err(e) = written
    {
        return Err(anyhow!("the send relay {program:?} did not read the whole message: {e}"));
    }
    Ok(Relayed {
        status,
        output: capture.then(|| String::from_utf8_lossy(&output).trim_end().to_owned()),
        stderr: capture.then(|| String::from_utf8_lossy(&stderr).trim_end().to_owned()),
    })
}

/// `acpmux send` to a target nobody here resolves, with a relay configured: run it, print what
/// it printed and exit with its status (a refusal is an error that exits with it).
pub(crate) fn send_with_deadline(
    config: &SendRelay,
    session: &str,
    text: &str,
    from: &RelayMetadata,
    attachments: bool,
    json_out: bool,
    deadline: Option<Instant>,
) -> Result<()> {
    if attachments {
        return Err(AppError::usage(format!(
            "no session {session:?} here or on a peer, and the send relay carries text only: send it without --attach"
        ))
        .into());
    }
    if !json_out {
        eprintln!("acpmux: no session {session:?} here or on a peer; handing it to the send relay");
    }
    let done = relay_with_deadline(config, session, text, from, json_out, deadline)?;
    audit_sent(session, text, from, &done);
    if let Some(said) = done.stderr.as_deref().filter(|s| !s.is_empty()) {
        eprintln!("{said}");
    }
    if json_out {
        print_json(&json!({
            "target": session,
            "status": if done.status == 0 { "relayed" } else { "refused" },
            "relayed": done.status == 0,
            "exit": done.status,
            "output": done.output,
        }));
    }
    let _ = std::io::stdout().flush();
    if done.status != 0 {
        let refused =
            format!("the send relay refused the message for {session:?} (exit {})", done.status);
        return Err(AppError::new(Code::Runtime, "relay_refused", refused)
            .with_exit(done.status)
            .into());
    }
    Ok(())
}

#[cfg(test)]
#[path = "send_relay_tests.rs"]
mod tests;
