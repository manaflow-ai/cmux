//! `acpmux session sleep-handoff [--dry-run]`: Settings > Agents > Keep Chats Running When This
//! Mac Sleeps. The app asks for it on the system's will-sleep notice (`_acpmux/sleep_handoff`,
//! `server/sleep_handoff.rs`); it moves each chat whose turn is running here to the machine the
//! person picked, and the turn goes on there.
//!
//! - Off unless `sessions.sleepHandoff.enabled` is true in the settings file
//!   (`schemas/settings/source/sessions.json`); `sessions.sleepHandoff.machine` is the target,
//!   a machine name or `auto` (`session move --machine auto`'s pick, never a machine a person
//!   works at).
//! - A chat moves when its turn runs, here (not a peer's), and it is no child chat (that runs
//!   with its parent) and shows no other app's conversation (`running_chats`).
//!   A parent whose child chats are open here stays (`family_refusal`): a move takes it alone.
//! - The move is `session move --interrupt --carry-changes` (`session_move::move_running`):
//!   the turn stops, the chat and its uncommitted work go, and there it is tagged
//!   `sleepHandoff=moved` with `sleepHandoffFrom` (this machine); the turn goes on there by the
//!   move's own continuation (`Cut::Move`), or, when automatic retries are off or spent and
//!   the move queued none, by a prompt that says so (`stalled`, `fallback_text`). Its copy here records where it went (`movedTo`, with
//!   `why: "sleep"`).
//! - A chat whose uncommitted work the carry would not take whole (a likely secret such as
//!   `.env`, a nested repository, edits inside a submodule: `session_move_carry.rs`,
//!   `dirty_submodules`) stays, before its turn is touched, and
//!   is tagged `sleepHandoff=stayed` with `sleepHandoffWhy` for a day (`carry_refusal`). The move
//!   checks the carry again after its freeze and fails rather than leave a file behind. A chat
//!   whose move fails stays the same way; a turn the failed move stopped goes on here by the same
//!   continuation, which the move gives back.

use super::*;
use crate::cli::run::session_move::{self, ContinueThere};
use crate::cli::session_move_carry as carry;
use std::path::{Path, PathBuf};

pub(crate) const SETTING_ENABLED: &str = "sessions.sleepHandoff.enabled";
pub(crate) const SETTING_MACHINE: &str = "sessions.sleepHandoff.machine";
/// The tag a chat the handoff touched carries: `moved` (on the target) or `stayed` (here).
pub(crate) const TAG: &str = "sleepHandoff";
/// On a moved chat: the machine it left.
pub(crate) const TAG_FROM: &str = "sleepHandoffFrom";
/// On a chat that stayed: why, in a sentence.
pub(crate) const TAG_WHY: &str = "sleepHandoffWhy";
/// How long a `stayed` mark lasts: past the night the Mac slept.
const STAYED_TTL_SECONDS: u64 = 24 * 60 * 60;

/// What the settings file asks for.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Settings {
    pub enabled: bool,
    pub machine: String,
}

/// The settings of `doc` (the settings file): off and `auto` when a key is missing or of
/// another type, as the schema's defaults are.
pub(crate) fn settings(doc: &Value) -> Settings {
    let get = |key: &str| crate::user_settings::value(doc, key);
    let enabled = get(SETTING_ENABLED).and_then(|v| v.as_bool()).unwrap_or(false);
    let machine = get(SETTING_MACHINE)
        .and_then(|v| v.as_str().map(str::trim).map(str::to_owned))
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| "auto".to_owned());
    Settings { enabled, machine }
}

/// The ids of the chats of `rows` (`_acpmux/sessions`) the handoff moves: a turn runs, here,
/// not a child chat, not watching another app, not being moved or moved away.
pub(crate) fn running_chats(rows: &[Value]) -> Vec<String> {
    let none = |s: &Value, key: &str| s.get(key).is_none_or(Value::is_null);
    rows.iter()
        .filter(|s| none(s, "peer") && none(s, "parent") && none(s, "watching"))
        .filter(|s| none(s, "movedTo") && s.get("moving").and_then(Value::as_bool) != Some(true))
        .filter(|s| !none(s, "turn") || s.get("status").and_then(Value::as_str) == Some("running"))
        .filter_map(|s| s.get("sessionId").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// Why the chat `row` (an `_acpmux/sessions` row) stays for its family: its child chats run on
/// this daemon, and a move takes the parent alone.
pub(crate) fn family_refusal(row: &Value) -> Option<String> {
    match row.get("children").and_then(Value::as_u64).unwrap_or(0) {
        0 => None,
        1 => Some("it has a child chat open here, which can't go with it".into()),
        n => Some(format!("it has {n} child chats open here, which can't go with it")),
    }
}

/// Whether the chat `info` (`_acpmux/info`, `_acpmux/tag`'s answer) is between turns with
/// nothing queued: the move left it no continuation.
pub(crate) fn stalled(info: &Value) -> bool {
    info.get("turn").is_none_or(Value::is_null)
        && info.get("status").and_then(Value::as_str) != Some("running")
        && info.get("queued").and_then(Value::as_u64).unwrap_or(0) == 0
}

/// The prompt that continues a moved turn when the move queued none.
pub(crate) fn fallback_text(host: &str) -> String {
    format!(
        "This Mac went to sleep, so this chat moved to {host} to keep going, and your turn was cut off. Continue where you left off."
    )
}

/// The submodules of the checkout `top` with changes of any kind (`git status --porcelain=v2`
/// marks them `S...`): the carry has no patch for them.
pub(crate) fn dirty_submodules(top: &Path) -> Result<Vec<String>> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(top)
        .args([
            "-c",
            "core.fsmonitor=false",
            "status",
            "--porcelain=v2",
            "--ignore-submodules=none",
        ])
        .output()?;
    if !out.status.success() {
        anyhow::bail!("git status: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(submodules_in_status(&String::from_utf8_lossy(&out.stdout)))
}

/// The submodule paths of `git status --porcelain=v2` output.
pub(crate) fn submodules_in_status(status: &str) -> Vec<String> {
    status
        .lines()
        .filter_map(|line| {
            let fields = match line.as_bytes().first() {
                Some(b'1') => 9,
                Some(b'2') => 10,
                _ => return None,
            };
            let parts: Vec<&str> = line.splitn(fields, ' ').collect();
            let sub = parts.get(2)?;
            let path = parts.get(fields - 1)?.split('\t').next()?;
            sub.starts_with('S').then(|| path.to_owned())
        })
        .collect()
}

/// Why a chat whose checkout has the changed submodules `subs` stays.
pub(crate) fn submodule_refusal(subs: &[String]) -> Option<String> {
    let (first, rest) = subs.split_first()?;
    let more = match rest.len() {
        0 => String::new(),
        n => format!(" and {n} more"),
    };
    Some(format!("its changes in the submodule {first}{more} can't go with it"))
}

/// Why a chat whose uncommitted work is `c` stays: the carry would leave some of it here.
pub(crate) fn carry_refusal(c: &carry::Carry) -> Option<String> {
    let ((path, why), rest) = c.left_out.split_first()?;
    let more = match rest.len() {
        0 => String::new(),
        n => format!(" and {n} more"),
    };
    Some(format!("its uncommitted {path} ({why}){more} can't go with it"))
}

/// One chat's outcome, as printed and in `--json`.
struct Outcome {
    session: String,
    moved_to: Option<String>,
    stayed: Option<String>,
}

pub(super) async fn run(dry_run: bool, json_out: bool) -> Result<()> {
    let wanted = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings(&doc),
        _ => settings(&Value::Null),
    };
    if !wanted.enabled {
        if json_out {
            print_json(&json!({"enabled": false, "chats": []}));
        } else {
            println!("Keep Chats Running When This Mac Sleeps is off: nothing moved");
        }
        return Ok(());
    }
    let src = connect(true).await?;
    let list = src.whole_list(method::MUX_SESSIONS, json!({})).await?;
    let rows = list.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
    let here = crate::pairing::machine_name();
    let mut outcomes = Vec::new();
    for id in running_chats(&rows) {
        let row = rows.iter().find(|r| r.get("sessionId").and_then(Value::as_str) == Some(&id));
        let outcome = match row.and_then(family_refusal) {
            Some(why) => Outcome { session: id.clone(), moved_to: None, stayed: Some(why) },
            None => handoff(&src, &id, &wanted.machine, &here, dry_run).await,
        };
        if let Some(why) = outcome.stayed.as_deref().filter(|_| !dry_run) {
            let set = json!({TAG: "stayed", TAG_WHY: why});
            let tag = json!({"sessionId": id, "set": set, "ttlSeconds": STAYED_TTL_SECONDS});
            if let Err(e) = src.request(method::MUX_TAG, tag).await {
                eprintln!("acpmux: {id} stayed, and its note did not save: {e:#}");
            }
        }
        outcomes.push(outcome);
    }
    if json_out {
        let chats: Vec<Value> = outcomes
            .iter()
            .map(|o| json!({"sessionId": o.session, "movedTo": o.moved_to, "stayed": o.stayed}))
            .collect();
        print_json(
            &json!({"enabled": true, "machine": wanted.machine, "dryRun": dry_run, "chats": chats}),
        );
    } else if outcomes.is_empty() {
        println!("no turn is running here: nothing moved");
    } else {
        for o in &outcomes {
            match (&o.moved_to, &o.stayed) {
                (Some(to), _) if dry_run => println!("{}: would move to {to}", o.session),
                (Some(to), _) => println!("{}: moved to {to}", o.session),
                (None, Some(why)) => println!("{}: stays here: {why}", o.session),
                (None, None) => println!("{}: stays here", o.session),
            }
        }
    }
    Ok(())
}

/// Moves the running chat `id` to `machine`, unless its uncommitted work would not go whole.
async fn handoff(
    src: &std::sync::Arc<Client>,
    id: &str,
    machine: &str,
    here: &str,
    dry_run: bool,
) -> Outcome {
    let mut o = Outcome { session: id.to_owned(), moved_to: None, stayed: None };
    match uncommitted_refusal(src, id).await {
        Ok(Some(why)) => {
            o.stayed = Some(why);
            return o;
        }
        Ok(None) => {}
        Err(e) => {
            o.stayed = Some(format!("its folder could not be read: {e:#}"));
            return o;
        }
    }
    if dry_run {
        o.moved_to = Some(machine.to_owned());
        return o;
    }
    let then = ContinueThere {
        why: "sleep",
        tags: json!({TAG: "moved", TAG_FROM: here}),
        fallback: fallback_text(machine),
    };
    match session_move::move_running(src, id, machine, then).await {
        Ok(moved) => {
            if let Err(why) = &moved.resumed {
                eprintln!(
                    "acpmux: {id} moved to {}, and its note there did not save: {why}",
                    moved.routed
                );
            }
            o.moved_to = Some(moved.routed);
        }
        Err(e) => {
            o.stayed = Some(format!("the move failed: {e:#}"));
        }
    }
    o
}

/// Why the chat `id` stays for its uncommitted work, read before its turn is touched.
async fn uncommitted_refusal(src: &Client, id: &str) -> Result<Option<String>> {
    let info = src.request(method::MUX_INFO, json!({"sessionId": id})).await?;
    let cwd = PathBuf::from(info.get("cwd").and_then(Value::as_str).unwrap_or_default());
    tokio::task::spawn_blocking(move || refusal_at(&cwd)).await?
}

/// Why a chat in the folder `cwd` stays: its checkout has uncommitted work the carry would not
/// take whole. None for a clean checkout or a folder in none (nothing of it moves).
pub(crate) fn refusal_at(cwd: &Path) -> Result<Option<String>> {
    let Some(checkout) = session_move::checkout_of(cwd)? else { return Ok(None) };
    if let Some(why) = submodule_refusal(&dirty_submodules(&checkout.top)?) {
        return Ok(Some(why));
    }
    if !checkout.dirty {
        return Ok(None);
    }
    let read = carry::snapshot(
        &|script, input| session_move::run_here(script, input),
        &checkout.top,
        true,
    )?;
    Ok(carry_refusal(&read))
}

#[cfg(test)]
#[path = "sleep_handoff_tests.rs"]
mod tests;
