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
//! - The move is `session move --interrupt --carry-changes` (`session_move::move_running`):
//!   the turn stops, the chat and its uncommitted work go, and there it is tagged
//!   `sleepHandoff=moved` with `sleepHandoffFrom` (this machine) and given a prompt that continues
//!   the turn. Its copy here records where it went (`movedTo`, with `why: "sleep"`).
//! - A chat whose uncommitted work the carry would not take whole (a likely secret such as
//!   `.env`, a nested repository: `session_move_carry.rs`) stays, before its turn is touched, and
//!   is tagged `sleepHandoff=stayed` with `sleepHandoffWhy` for a day (`carry_refusal`). So does
//!   a chat whose move fails; one stopped by a move that then failed gets its prompt here.

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

/// Why a chat whose uncommitted work is `c` stays: the carry would leave some of it here.
pub(crate) fn carry_refusal(c: &carry::Carry) -> Option<String> {
    let ((path, why), rest) = c.left_out.split_first()?;
    let more = match rest.len() {
        0 => String::new(),
        n => format!(" and {n} more"),
    };
    Some(format!("its uncommitted {path} ({why}){more} can't go with it"))
}

/// The prompt that continues a moved chat's turn on `host`.
pub(crate) fn continue_text(host: &str) -> String {
    format!(
        "This Mac went to sleep, so this chat moved to {host} to keep going. Continue where you left off."
    )
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
        let outcome = handoff(&src, &id, &wanted.machine, &here, dry_run).await;
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
        text: continue_text(machine),
    };
    match session_move::move_running(src, id, machine, then).await {
        Ok(moved) => {
            if let Err(why) = &moved.resumed {
                eprintln!(
                    "acpmux: {id} moved to {}, and its turn did not go on: {why}",
                    moved.routed
                );
            }
            o.moved_to = Some(moved.routed);
        }
        Err(e) => {
            o.stayed = Some(format!("the move failed: {e:#}"));
            continue_here(src, id).await;
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

/// A chat whose move failed after its turn was stopped goes on here.
async fn continue_here(src: &std::sync::Arc<Client>, id: &str) {
    let Ok(info) = src.request(method::MUX_INFO, json!({"sessionId": id})).await else { return };
    let stopped = info.get("turn").is_none_or(Value::is_null)
        && info.get("status").and_then(Value::as_str) != Some("running")
        && info.get("moving").and_then(Value::as_bool) != Some(true);
    if !stopped {
        return;
    }
    let text = "This Mac was going to sleep and moving this chat failed, so it stayed here. Continue where you left off.";
    let prompt = crate::cli::output::PromptId::new(None);
    if let Err(e) =
        crate::cli::output::queue_prompt(src.clone(), id, text, false, None, &prompt).await
    {
        eprintln!("acpmux: {id} stayed, and its turn did not go on: {e:#}");
    }
}

#[cfg(test)]
#[path = "sleep_handoff_tests.rs"]
mod tests;
