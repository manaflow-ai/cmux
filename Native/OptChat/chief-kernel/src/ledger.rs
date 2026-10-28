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
//! - **Ask ledger.** One person message often holds several asks. A turn
//!   records the asks it took (`asks_taken`), each with an owner: a subagent
//!   id, `me` (Chief does it itself), or `declined` with a reason. A spawn the
//!   turn asked for (`spawn_requested`) comes back as one keyed `spawn` intent
//!   per task, so the host starts each agent once, even when a turn replays;
//!   `spawn_started` names its agent as the ask's owner, and that agent's
//!   report (`outcome_reported`) marks the ask done. When every ask of a
//!   message has an owner, an `ack` intent marks it. An ask with no owner
//!   after its turn ends gets an `[unowned]` retry note, once.
//!
//! - **Schedule ledger.** A Chief's jobs: `schedule_set` keeps one (a 5-field
//!   cron on the person's clock, `ctx.utc_offset_minutes`, or a one-shot
//!   `at_ms`), `schedule_removed` drops it. When a slot is due and no turn
//!   runs, `check_due` fires it as a `[schedule <id>] <prompt>` notice keyed
//!   `fire-<id>-<slot>`; a computer that slept through several slots fires it
//!   once, for the latest. A recurring job expires `SCHEDULE_TTL` after it was
//!   set unless it names `expires_ms`, with one note when it does.
//!
//! Events: `message_logged {id, seq, text, from_person}`, `turn_started
//! {seen: [message ids], reports: [subagent ids]}`, `reply_posted {answers?,
//! reply_to?, chief, text}`, `turn_ended {said_no_reply}`, `outcome_reported
//! {id, stopped}`, `asks_taken {message, asks: [{ask, owner?, reason?}]}`,
//! `spawn_requested {message, tasks: [{ask, task}]}`, `spawn_started {key,
//! id}`, `schedule_set {id, cron | at_ms, prompt, expires_ms?}`,
//! `schedule_removed {id}`, `check_due`. Intents: `schedule {at_ms, key}`, `notice {text, key}`
//! (a note that starts a turn), `post {text, reply_to, key}`, `spawn {task,
//! message, key}`, `ack {message, key}`.

use crate::cron::Cron;
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

/// The first word of an unowned-ask retry turn's note.
pub const UNOWNED_TAG: &str = "[unowned]";

/// The wait after a turn that left an ask with no owner, before its check.
pub const UNOWNED_WAIT: u64 = 5_000;

/// Retry turns per unowned ask before it is dropped.
pub const MAX_UNOWNED_TRIES: u32 = 1;

/// How long a recurring job lives when it names no expiry: 7 days.
pub const SCHEDULE_TTL: u64 = 7 * 24 * 3_600_000;

/// The first word of a scheduled job's note.
pub const SCHEDULE_TAG: &str = "[schedule";

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
    /// The asks the person's messages hold, with their owners.
    #[serde(default)]
    pub asks: Vec<Ask>,
    /// The Chief's scheduled jobs.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub schedules: Vec<Schedule>,
    /// A turn runs now.
    #[serde(default)]
    pub turn_running: bool,
}

/// A recurring (cron) or one-shot (at) job of the Chief.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Schedule {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cron: Option<String>,
    pub prompt: String,
    /// Its next slot (UTC ms).
    pub next_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_ms: Option<u64>,
    /// A running turn held its firing until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold_ms: Option<u64>,
}

impl Schedule {
    fn due_at(&self) -> u64 {
        self.next_ms.max(self.hold_ms.unwrap_or(0))
    }

    /// When a check must look at it: its slot, or its expiry when sooner.
    fn check_at(&self) -> u64 {
        self.expires_ms
            .map_or(self.due_at(), |e| e.min(self.due_at()))
    }
}

/// One ask of a person message.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ask {
    /// The message it came from.
    pub message: String,
    /// The ask, in a few words.
    pub ask: String,
    /// A subagent id, `me`, or `declined`; None: nobody has it yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// The spawn intent's key that will own it, until its agent starts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawn_key: Option<String>,
    /// Its subagent reported (or it was `me`/`declined` and the turn ended).
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub tries: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_ms: Option<u64>,
}

#[derive(Deserialize)]
struct AskIn {
    ask: String,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Deserialize)]
struct TaskIn {
    #[serde(default)]
    ask: String,
    task: String,
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
    AsksTaken {
        message: String,
        asks: Vec<AskIn>,
    },
    SpawnRequested {
        message: String,
        tasks: Vec<TaskIn>,
    },
    SpawnStarted {
        key: String,
        id: String,
    },
    ScheduleSet {
        id: String,
        #[serde(default)]
        cron: Option<String>,
        #[serde(default)]
        at_ms: Option<u64>,
        prompt: String,
        #[serde(default)]
        expires_ms: Option<u64>,
    },
    ScheduleRemoved {
        id: String,
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
    let offset = ctx
        .get("utc_offset_minutes")
        .and_then(Value::as_i64)
        .unwrap_or(0);
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
            for a in s
                .asks
                .iter_mut()
                .filter(|a| a.owner.is_none() && a.spawn_key.is_none() && a.due_ms.is_none())
            {
                a.due_ms = Some(now + UNOWNED_WAIT);
            }
            // An ask Chief did itself, or declined, is done with its turn.
            for a in s
                .asks
                .iter_mut()
                .filter(|a| matches!(a.owner.as_deref(), Some("me" | "declined")))
            {
                a.done = true;
            }
            s.asks.retain(|a| !a.done);
            schedule_next(&s, &mut intents);
        }
        Event::OutcomeReported { id, stopped } => {
            for a in s
                .asks
                .iter_mut()
                .filter(|a| a.owner.as_deref() == Some(id.as_str()))
            {
                a.done = true;
                a.due_ms = None;
            }
            if !stopped && !s.untold.iter().any(|u| u.id == id) {
                s.untold.push(Untold {
                    id,
                    ..Untold::default()
                });
            }
        }
        Event::AsksTaken { message, asks } => {
            for a in asks {
                let owner = a.owner.filter(|o| !o.trim().is_empty());
                match s
                    .asks
                    .iter_mut()
                    .find(|x| x.message == message && x.ask == a.ask)
                {
                    Some(x) => {
                        if owner.is_some() {
                            x.owner = owner;
                            x.reason = a.reason;
                            x.due_ms = None;
                        }
                    }
                    None => s.asks.push(Ask {
                        message: message.clone(),
                        ask: a.ask,
                        owner,
                        reason: a.reason,
                        ..Ask::default()
                    }),
                }
            }
            ack_if_owned(&s, &message, &mut intents);
        }
        Event::SpawnRequested { message, tasks } => {
            for (k, t) in tasks.into_iter().enumerate() {
                let key = format!("spawn-{message}-{k}");
                if s.asks
                    .iter()
                    .any(|a| a.spawn_key.as_deref() == Some(key.as_str()))
                {
                    continue;
                }
                let ask = if t.ask.trim().is_empty() {
                    first_line(&t.task)
                } else {
                    t.ask
                };
                match s
                    .asks
                    .iter_mut()
                    .find(|a| a.message == message && a.ask == ask)
                {
                    Some(a) => a.spawn_key = Some(key.clone()),
                    None => s.asks.push(Ask {
                        message: message.clone(),
                        ask,
                        spawn_key: Some(key.clone()),
                        ..Ask::default()
                    }),
                }
                intents
                    .push(json!({"kind": "spawn", "task": t.task, "message": message, "key": key}));
            }
        }
        Event::SpawnStarted { key, id } => {
            let mut message = None;
            for a in s
                .asks
                .iter_mut()
                .filter(|a| a.spawn_key.as_deref() == Some(key.as_str()))
            {
                a.owner = Some(id.clone());
                a.due_ms = None;
                message = Some(a.message.clone());
            }
            if let Some(m) = message {
                ack_if_owned(&s, &m, &mut intents);
            }
        }
        Event::ScheduleSet {
            id,
            cron,
            at_ms,
            prompt,
            expires_ms,
        } => {
            if id.trim().is_empty() || prompt.trim().is_empty() {
                return Err("schedule_set: `id` and `prompt` are required".into());
            }
            let (next_ms, expires_ms) = match (&cron, at_ms) {
                (Some(c), None) => {
                    let next = Cron::parse(c)?
                        .next_after(now, offset)
                        .ok_or_else(|| format!("schedule_set: cron {c:?} never fires"))?;
                    (next, Some(expires_ms.unwrap_or(now + SCHEDULE_TTL)))
                }
                (None, Some(at)) => (at, expires_ms),
                _ => return Err("schedule_set: give exactly one of `cron` and `at_ms`".into()),
            };
            s.schedules.retain(|j| j.id != id);
            s.schedules.push(Schedule {
                id,
                cron,
                prompt,
                next_ms,
                expires_ms,
                hold_ms: None,
            });
            schedule_next(&s, &mut intents);
        }
        Event::ScheduleRemoved { id } => {
            s.schedules.retain(|j| j.id != id);
            schedule_next(&s, &mut intents);
        }
        Event::CheckDue => {
            fire_schedules(&mut s, now, offset, &mut intents);
            fire(&mut s, now, &mut intents);
        }
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
        for a in s.asks.iter_mut().filter(|a| due(a.due_ms)) {
            a.due_ms = Some(now + UNOWNED_WAIT);
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
    let mut unowned: Vec<Ask> = Vec::new();
    for a in s
        .asks
        .iter_mut()
        .filter(|a| due(a.due_ms) && a.owner.is_none())
    {
        if a.tries >= MAX_UNOWNED_TRIES {
            a.done = true;
            continue;
        }
        a.tries += 1;
        a.due_ms = None;
        unowned.push(a.clone());
    }
    s.asks.retain(|a| !a.done);
    if !unowned.is_empty() {
        intents.push(json!({
            "kind": "notice",
            "text": unowned_note(&unowned),
            "key": format!("unowned-retry-{now}"),
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
        .chain(s.asks.iter().filter_map(|a| a.due_ms))
        .chain(s.schedules.iter().map(Schedule::check_at))
        .min();
    if let Some(at) = next {
        intents.push(json!({"kind": "schedule", "at_ms": at, "key": format!("reply-check-{at}")}));
    }
}

/// The scheduled jobs due at `now`: a running turn holds them a little; else
/// each fires once for its latest due slot, and an expired one is dropped
/// with a note. `fire` asks for the next check after.
fn fire_schedules(s: &mut Ledgers, now: u64, offset: i64, intents: &mut Vec<Value>) {
    if s.turn_running {
        for j in s.schedules.iter_mut().filter(|j| j.due_at() <= now) {
            j.hold_ms = Some(now + REPLY_RETRY_WAITS[0]);
        }
        return;
    }
    let mut expired: Vec<String> = Vec::new();
    for j in s.schedules.iter_mut() {
        let limit = j.expires_ms.map_or(now, |e| e.min(now));
        if j.due_at() <= now && j.next_ms <= limit {
            // The latest slot it missed; the ones before it fire nothing.
            let cron = j.cron.as_deref().and_then(|c| Cron::parse(c).ok());
            let mut slot = j.next_ms;
            let mut missed = 1u32;
            let mut next = None;
            if let Some(cron) = &cron {
                loop {
                    match cron.next_after(slot, offset) {
                        Some(n) if n <= limit => {
                            slot = n;
                            missed += 1;
                        }
                        n => {
                            next = n;
                            break;
                        }
                    }
                }
            }
            let mut text = format!("{SCHEDULE_TAG} {}] {}", j.id, j.prompt);
            if missed > 1 {
                text.push_str(&format!(
                    "\n(This computer slept through {missed} of its times; it runs once now.)"
                ));
            }
            intents.push(
                json!({"kind": "notice", "text": text, "key": format!("fire-{}-{slot}", j.id)}),
            );
            j.hold_ms = None;
            match next {
                Some(n) => j.next_ms = n,
                None => expired.push(j.id.clone()),
            }
            if cron.is_none() {
                continue;
            }
        }
        if j.expires_ms.is_some_and(|e| e <= now) && !expired.contains(&j.id) {
            intents.push(json!({
                "kind": "notice",
                "text": format!(
                    "{SCHEDULE_TAG} {}] expired: \"{}\" no longer runs. Set it again if the person still wants it.",
                    j.id, preview(&j.prompt)
                ),
                "key": format!("expired-{}", j.id),
            }));
            expired.push(j.id.clone());
        }
    }
    s.schedules.retain(|j| !expired.contains(&j.id));
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

/// An `ack` intent when every recorded ask of `message` has an owner.
fn ack_if_owned(s: &Ledgers, message: &str, intents: &mut Vec<Value>) {
    let mut asks = s.asks.iter().filter(|a| a.message == message).peekable();
    if asks.peek().is_none() {
        return;
    }
    if asks.all(|a| a.owner.is_some()) {
        intents.push(json!({"kind": "ack", "message": message, "key": format!("ack-{message}")}));
    }
}

fn first_line(text: &str) -> String {
    let line = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or_default()
        .trim();
    line.strip_prefix("Title:")
        .map(str::trim)
        .unwrap_or(line)
        .chars()
        .take(PREVIEW_CHARS)
        .collect()
}

fn unowned_note(asks: &[Ask]) -> String {
    let lines: Vec<String> = asks
        .iter()
        .map(|a| format!("- \"{}\" (message {})", a.ask, a.message))
        .collect();
    format!(
        "{UNOWNED_TAG} These asks of the user have no owner yet:\n{}\nFor each, start it (spawn), do it yourself, or say in one line why not; then say which in your reply.",
        lines.join("\n")
    )
}
