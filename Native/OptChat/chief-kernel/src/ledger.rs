//! The reply and outcome ledgers as a pure fold (cloud-chief-durable-DESIGN.md
//! section 13, export 3): the kernel decides, the host acts.
//!
//! `ledger_apply(state, event, ctx) -> {state, intents}`. The host stores
//! `state` with its own rows in one transaction, and performs each intent
//! with its key, so a crash never leaves one without the other. Time comes in
//! `ctx.now_ms`; nothing here reads a clock.
//!
//! The rules are the Mac host's (optchat-chief `brain/reply_ledger.rs` and
//! `brain/outcome_ledger.rs`):
//!
//! - **Reply ledger.** A person message waits until a Chief post answers it
//!   (a post that names it, or any Chief post once a turn has seen it). A turn
//!   that ends without one leaves a check after `REPLY_RETRY_WAITS[tries]`.
//!   When the check is due and no turn runs, a retry turn starts on a `[no
//!   reply]` note (`notice`). After `MAX_REPLY_TRIES` retries, the host posts
//!   a failure note in the message's thread (`post`). A host notice answers
//!   nothing.
//! - **Outcome ledger.** A finished subagent (not one the person stopped)
//!   waits until a Chief post names it as a word. A turn that saw its report
//!   and ended without naming it leaves a check; one `[untold]` retry note,
//!   then it is dropped. The host never posts on the Chief's behalf here.
//!
//! Events: `message_logged {id, seq, text, from_person}`, `turn_started
//! {seen: [message ids], reports: [subagent ids]}`, `reply_posted {answers?,
//! reply_to?, chief, text}`, `turn_ended {said_no_reply}`, `outcome_reported
//! {id, stopped}`, `check_due`. Intents: `schedule {at_ms, key}`, `notice
//! {text, key}` (a note that starts a turn), `post {text, reply_to, key}`.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The waits before each reply check, in ms: after the turn that left a
/// message unanswered ends, and between retries.
pub const REPLY_RETRY_WAITS: [u64; 3] = [5_000, 30_000, 120_000];

/// Retry turns per message before the failure post.
pub const MAX_REPLY_TRIES: u32 = 3;

/// The wait after a turn that saw a report, before its outcome check.
pub const UNTOLD_WAIT: u64 = 5_000;

/// Retry turns per subagent before it is dropped.
pub const MAX_UNTOLD_TRIES: u32 = 1;

/// The first word of a reply retry turn's note.
pub const NO_REPLY_TAG: &str = "[no reply]";

/// The first word of an outcome retry turn's note.
pub const UNTOLD_TAG: &str = "[untold]";

const PREVIEW_CHARS: usize = 120;
const WHY_NO_REPLY: &str = "the turn ended with NO_REPLY";
const WHY_SILENT: &str = "the turn ended without a reply";

/// The ledgers' state, as the host stores it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ledgers {
    /// Person messages that wait for a reply.
    #[serde(default)]
    pub awaiting: Vec<Awaiting>,
    /// Finished subagents whose outcome no Chief post told yet.
    #[serde(default)]
    pub untold: Vec<Untold>,
    /// A turn runs now.
    #[serde(default)]
    pub turn_running: bool,
}

/// A person message that waits for a reply.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Awaiting {
    pub id: String,
    pub seq: u64,
    pub preview: String,
    /// A turn has seen it.
    #[serde(default)]
    pub seen: bool,
    #[serde(default)]
    pub tries: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}

/// A finished subagent whose outcome waits to be told.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Untold {
    pub id: String,
    /// A turn has seen its report.
    #[serde(default)]
    pub seen: bool,
    #[serde(default)]
    pub tries: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    MessageLogged {
        id: String,
        #[serde(default)]
        seq: u64,
        #[serde(default)]
        text: String,
        #[serde(default)]
        from_person: bool,
    },
    TurnStarted {
        #[serde(default)]
        seen: Vec<String>,
        #[serde(default)]
        reports: Vec<String>,
    },
    ReplyPosted {
        #[serde(default)]
        answers: Vec<String>,
        #[serde(default)]
        reply_to: Option<String>,
        #[serde(default)]
        chief: bool,
        #[serde(default)]
        text: String,
    },
    TurnEnded {
        #[serde(default)]
        said_no_reply: bool,
    },
    OutcomeReported {
        id: String,
        #[serde(default)]
        stopped: bool,
    },
    CheckDue,
}

/// Applies `event_json` to `state_json` at `ctx_json.now_ms`; answers
/// `{state, intents}` as JSON. An empty state is `{}`.
pub fn ledger_apply(state_json: &str, event_json: &str, ctx_json: &str) -> Result<String, String> {
    let mut s: Ledgers = serde_json::from_str(state_json).map_err(|e| format!("state: {e}"))?;
    let event: Event = serde_json::from_str(event_json).map_err(|e| format!("event: {e}"))?;
    let ctx: Value = serde_json::from_str(ctx_json).map_err(|e| format!("ctx: {e}"))?;
    let now = ctx
        .get("now_ms")
        .and_then(Value::as_u64)
        .ok_or("ctx: `now_ms` is required")?;
    let mut intents: Vec<Value> = Vec::new();
    match event {
        Event::MessageLogged {
            id,
            seq,
            text,
            from_person,
        } => {
            if from_person && !id.is_empty() && !s.awaiting.iter().any(|a| a.id == id) {
                s.awaiting.push(Awaiting {
                    id,
                    seq,
                    preview: preview(&text),
                    ..Awaiting::default()
                });
            }
        }
        Event::TurnStarted { seen, reports } => {
            s.turn_running = true;
            for a in s.awaiting.iter_mut().filter(|a| seen.contains(&a.id)) {
                a.seen = true;
                a.due_ms = None;
            }
            for u in s.untold.iter_mut().filter(|u| reports.contains(&u.id)) {
                u.seen = true;
            }
        }
        Event::ReplyPosted {
            answers,
            reply_to,
            chief,
            text,
        } => {
            if !text.trim().is_empty() {
                let mut named = answers;
                named.extend(reply_to);
                s.awaiting
                    .retain(|a| !(named.contains(&a.id) || (chief && a.seen)));
                if chief {
                    s.untold.retain(|u| !names(&text, &u.id));
                }
            }
        }
        Event::TurnEnded { said_no_reply } => {
            s.turn_running = false;
            let why = if said_no_reply {
                WHY_NO_REPLY
            } else {
                WHY_SILENT
            };
            for a in s
                .awaiting
                .iter_mut()
                .filter(|a| a.seen && a.due_ms.is_none())
            {
                a.due_ms = Some(now + wait_of(a.tries));
                a.why = Some(why.to_owned());
            }
            for u in s.untold.iter_mut().filter(|u| u.seen && u.due_ms.is_none()) {
                u.due_ms = Some(now + UNTOLD_WAIT);
            }
            schedule_next(&s, &mut intents);
        }
        Event::OutcomeReported { id, stopped } => {
            if !stopped && !s.untold.iter().any(|u| u.id == id) {
                s.untold.push(Untold {
                    id,
                    ..Untold::default()
                });
            }
        }
        Event::CheckDue => fire(&mut s, now, &mut intents),
    }
    Ok(json!({"state": s, "intents": intents}).to_string())
}

/// The due checks at `now`: a running turn moves them later; else a retry
/// note for the messages and subagents due, and a failure post for the
/// messages out of tries.
fn fire(s: &mut Ledgers, now: u64, intents: &mut Vec<Value>) {
    let due = |d: Option<u64>| d.is_some_and(|d| d <= now);
    if s.turn_running {
        for a in s.awaiting.iter_mut().filter(|a| due(a.due_ms)) {
            a.due_ms = Some(now + REPLY_RETRY_WAITS[0]);
        }
        for u in s.untold.iter_mut().filter(|u| due(u.due_ms)) {
            u.due_ms = Some(now + UNTOLD_WAIT);
        }
        schedule_next(s, intents);
        return;
    }
    let mut retry: Vec<Awaiting> = Vec::new();
    let mut failed: Vec<Awaiting> = Vec::new();
    for a in s.awaiting.iter_mut().filter(|a| due(a.due_ms)) {
        if a.tries >= MAX_REPLY_TRIES {
            failed.push(a.clone());
            continue;
        }
        a.tries += 1;
        // The retry turn sees it again; its end sets the next check.
        a.due_ms = None;
        retry.push(a.clone());
    }
    let failed_ids: Vec<String> = failed.iter().map(|a| a.id.clone()).collect();
    s.awaiting.retain(|a| !failed_ids.contains(&a.id));
    for a in &failed {
        let why = a.why.as_deref().unwrap_or(WHY_SILENT);
        intents.push(json!({
            "kind": "post",
            "text": failure_text(&a.preview, why, a.tries),
            "reply_to": a.id,
            "key": format!("no-reply-{}", a.id),
        }));
    }
    if !retry.is_empty() {
        intents.push(json!({
            "kind": "notice",
            "text": no_reply_note(&retry),
            "key": format!("no-reply-retry-{now}"),
        }));
    }
    let mut told_again: Vec<String> = Vec::new();
    let mut dropped: Vec<String> = Vec::new();
    for u in s.untold.iter_mut().filter(|u| due(u.due_ms)) {
        if u.tries >= MAX_UNTOLD_TRIES {
            dropped.push(u.id.clone());
            continue;
        }
        u.tries += 1;
        u.due_ms = None;
        told_again.push(u.id.clone());
    }
    s.untold.retain(|u| !dropped.contains(&u.id));
    if !told_again.is_empty() {
        intents.push(json!({
            "kind": "notice",
            "text": untold_note(&told_again),
            "key": format!("untold-retry-{now}"),
        }));
    }
    schedule_next(s, intents);
}

/// One `schedule` intent for the earliest pending check, keyed by its time so
/// a repeated fold asks for it once.
fn schedule_next(s: &Ledgers, intents: &mut Vec<Value>) {
    let next = s
        .awaiting
        .iter()
        .filter_map(|a| a.due_ms)
        .chain(s.untold.iter().filter_map(|u| u.due_ms))
        .min();
    if let Some(at) = next {
        intents.push(json!({"kind": "schedule", "at_ms": at, "key": format!("reply-check-{at}")}));
    }
}

fn wait_of(tries: u32) -> u64 {
    REPLY_RETRY_WAITS
        .get(tries as usize)
        .or(REPLY_RETRY_WAITS.last())
        .copied()
        .unwrap_or_default()
}

/// Whether `text` names subagent `id` as a word (`a1` is not in `a12`).
fn names(text: &str, id: &str) -> bool {
    let word = |c: Option<char>| c.is_some_and(|c| c.is_alphanumeric() || c == '_');
    text.match_indices(id).any(|(at, _)| {
        !word(text[..at].chars().next_back()) && !word(text[at + id.len()..].chars().next())
    })
}

fn preview(text: &str) -> String {
    let line = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or_default()
        .trim();
    let mut out: String = line.chars().take(PREVIEW_CHARS).collect();
    if line.chars().count() > PREVIEW_CHARS {
        out.push('…');
    }
    out
}

/// The text the person sees when no turn could answer a message.
pub fn failure_text(preview: &str, why: &str, tries: u32) -> String {
    format!(
        "I could not answer your message \"{preview}\". I tried {} times and {why}. Please send it again.",
        tries + 1
    )
}

fn no_reply_note(due: &[Awaiting]) -> String {
    let lines: Vec<String> = due
        .iter()
        .map(|a| {
            format!(
                "- message {} \"{}\" ({}; retry {} of {MAX_REPLY_TRIES})",
                a.id,
                a.preview,
                a.why.as_deref().unwrap_or(WHY_SILENT),
                a.tries
            )
        })
        .collect();
    format!(
        "{NO_REPLY_TAG} These messages of the user got no reply:\n{}\nReply to each now, in words (send, reply, or your final text). NO_REPLY and a stop with nothing sent are not allowed for a person's message in this chat. If you cannot do what it asks, say so and why.",
        lines.join("\n")
    )
}

fn untold_note(ids: &[String]) -> String {
    format!(
        "{UNTOLD_TAG} These subagents finished and the person has not been told their outcome: {}.\n\
         Tell the person now, one line each, naming each id: what changed and its link, what is \
         still open, and what you do about it (follow up, restart, or done). If one needs nothing \
         from them, still say its result in that one line.",
        ids.join(", ")
    )
}
