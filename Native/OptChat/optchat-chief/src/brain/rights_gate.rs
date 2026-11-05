//! The rights table (rights.rs) and the audit log (audit.rs) in the brain.
//!
//! - Admission: a person's message that would wake the Chief is checked
//!   before it is queued. Another person's prompt on a personal login is a
//!   suggestion (no turn); a person or the Chief over its daily cap gets one
//!   line saying so (no turn); the chat commands (`/audit`, `/rights`,
//!   `/grant`, `/revoke`, `/approver`, `/cap`, `/auth`) are answered by the
//!   host itself (no turn). An approver's message runs without the floor.
//! - The turn's people: the authors of the messages a turn carries.
//! - The turn session's tool hook (`optchat-chief rights-hook pre|post`, in
//!   the turn folder's settings) asks the host about each call: in a turn
//!   that carries another person's text, a call their grants cover is allowed
//!   by the hook (Claude Code then asks nobody); any other call gets no
//!   answer from the hook, so it reaches the ask floor and is refused there
//!   (fail closed). Every call, the owner's included, is audited before and
//!   after it runs, with its output's digest.
//! - Turn end: the turn's cost is audited as `spend` against its people.

use std::collections::HashMap;
use std::path::PathBuf;

use cmux_conversation::{Message, Op, Summary};
use serde_json::{Value, json};

use super::Brain;
use crate::audit::{self, Entry};
use crate::rights::{AuthKind, Decision, Rights};

/// What the brain keeps for the rights table.
#[derive(Clone, Debug, Default)]
pub struct RightsCtx {
    /// The optchat root (`$MUX_HOME/optchat`): rights.json and audit/.
    pub root: PathBuf,
    /// What the host's environment shows about its model login.
    pub detected: Option<AuthKind>,
    /// This host's name, for the audit's `host`.
    pub host: String,
    /// The working directory of turns, for the audit's `cwd`.
    pub cwd: Option<String>,
    /// The person behind each queued message id.
    pub(super) authors: HashMap<String, String>,
    /// The people of the running turn (the owner alone for an owner turn).
    pub(super) turn_people: Vec<String>,
    /// The running turn's key, for the audit's `via`.
    pub(super) turn_key: Option<String>,
}

/// What admission decided for a message.
pub(super) enum Admit {
    /// Queue it; `lifts_floor`: its author's word counts as the owner's.
    Queue { lifts_floor: bool },
    /// The host answered it (a command, a suggestion, a cap); no turn.
    Answered,
}

/// The chat commands the host answers itself.
const COMMANDS: [&str; 7] = [
    "/audit",
    "/rights",
    "/grant",
    "/revoke",
    "/approver",
    "/cap",
    "/auth",
];

/// The id of a person no message named (fail closed in `decide`).
const UNKNOWN: &str = "unknown-person";
/// The person of another agent's words sent through the owner's CLI: no
/// table entry can name it, so it holds no grants.
const AGENT_SENT: &str = "agent-via-owner-cli";

impl RightsCtx {
    pub fn new(
        root: PathBuf,
        detected: Option<AuthKind>,
        host: String,
        cwd: Option<String>,
    ) -> RightsCtx {
        RightsCtx {
            root,
            detected,
            host,
            cwd,
            ..RightsCtx::default()
        }
    }
}

impl Brain {
    /// Turns the rights table and the audit on (the host does; tests may).
    pub fn with_rights(mut self, ctx: RightsCtx) -> Brain {
        self.rights = Some(ctx);
        self
    }

    /// [`Self::with_rights`] on a brain already made.
    pub fn set_rights(&mut self, ctx: RightsCtx) {
        self.rights = Some(ctx);
    }

    /// The table as it is on disk now; one that does not parse grants
    /// nothing (logged).
    fn rights_table(&self) -> Rights {
        let Some(ctx) = &self.rights else {
            return Rights::default();
        };
        Rights::load(&Rights::path(&ctx.root)).unwrap_or_else(|e| {
            (self.log)(&format!("rights table unreadable, granting nothing: {e}"));
            // Keep the owner's own declarations off too: personal, no people.
            Rights::default()
        })
    }

    fn audit(&self, entry: Entry) {
        let Some(ctx) = &self.rights else { return };
        let mut entry = entry;
        entry.host.get_or_insert_with(|| ctx.host.clone());
        if entry.cwd.is_none() {
            entry.cwd = ctx.cwd.clone();
        }
        match audit::append(&ctx.root, &entry) {
            Ok(r) => (self.log)(&format!("audit #{} {}", r.seq, &r.hash[..16])),
            Err(e) => (self.log)(&format!("audit append failed: {e}")),
        }
    }

    /// The person a message speaks for: another Chief as `chief:<its id>`
    /// (never an approver), a paired device as its `person`, else its
    /// author id.
    pub(super) fn person_of(summary: &Summary, message: &Message) -> String {
        let participant = summary.participants.iter().find(|p| p.id == message.author);
        match participant {
            Some(p) if p.kind == cmux_conversation::ParticipantKind::Agent => {
                format!("{}{}", crate::rights::CHIEF_PREFIX, p.id)
            }
            Some(p) => p.person.clone().unwrap_or_else(|| p.id.clone()),
            None => message.author.clone(),
        }
    }

    /// A chat command (`/audit`, `/rights`, `/grant`, `/revoke`,
    /// `/approver`, `/cap`, `/auth`) from a person in the conversation,
    /// answered by the host whether or not the message would wake the Chief
    /// (a shared chat wakes it only on a mention). True: answered.
    pub(super) fn try_command(
        &mut self,
        summary: &Summary,
        message: &Message,
        text: &str,
        target: Option<&str>,
    ) -> bool {
        if self.rights.is_none() {
            return false;
        }
        let trimmed = text.trim();
        let verb = trimmed.split_whitespace().next().unwrap_or("");
        if !COMMANDS.contains(&verb) {
            return false;
        }
        let human = summary
            .participants
            .iter()
            .any(|p| p.id == message.author && p.kind == cmux_conversation::ParticipantKind::Human);
        if !human || message.author == self.settings.membership.participant {
            return false;
        }
        let owner_msg = self.settings.membership.is_owner_message(summary, message);
        let owner = self.settings.membership.owner.clone();
        // Another agent's words through the owner's CLI change nothing.
        let person = if owner_msg {
            owner.clone()
        } else {
            Self::person_of(summary, message)
        };
        if !owner_msg && person == owner {
            return false;
        }
        let rights = self.rights_table();
        match self.command(&rights, summary, &person, owner_msg, trimmed, &message.id) {
            Some(answer) => {
                self.answer_message(target, message, "rights", &answer);
                true
            }
            None => false,
        }
    }

    /// Admission of a waking human message (README "Multiplayer rights").
    /// Without the rights table, every message queues as before.
    pub(super) fn admit(
        &mut self,
        summary: &Summary,
        message: &Message,
        text: &str,
        owner_msg: bool,
        target: Option<&str>,
    ) -> Admit {
        if self.rights.is_none() {
            return Admit::Queue { lifts_floor: false };
        }
        let owner = self.settings.membership.owner.clone();
        let person = if owner_msg {
            owner.clone()
        } else {
            Self::person_of(summary, message)
        };
        let rights = self.rights_table();
        let trimmed = text.trim();
        if trimmed.starts_with('/')
            && let Some(answer) =
                self.command(&rights, summary, &person, owner_msg, trimmed, &message.id)
        {
            self.answer_message(target, message, "rights", &answer);
            return Admit::Answered;
        }
        let detected = self.rights.as_ref().and_then(|c| c.detected);
        // The owner's own CLI carrying another agent's words (`[from NAME]`,
        // README "Remote-origin messages"): not another person, but still
        // under the floor with no grants, as before.
        let agent_sent = !owner_msg && person == owner;
        if !owner_msg
            && !agent_sent
            && let Err(why) = rights.may_prompt(&owner, &person, detected)
        {
            {
                let name = display_name(summary, &message.author);
                self.audit(Entry {
                    who: vec![person.clone()],
                    tool: "prompt".into(),
                    what: format!("message {}", message.id),
                    input_sha256: Some(audit::sha256(text.as_bytes())),
                    decision: "deny".into(),
                    by: Some(format!("auth: {}", rights.auth_kind(detected).as_str())),
                    ..Entry::default()
                });
                self.answer_message(
                    target,
                    message,
                    "suggestion",
                    &format!("Not run: {why}. ({name}'s message stays here for the owner.)"),
                );
                return Admit::Answered;
            }
        }
        if let Some(why) = self.over_cap(&rights, &owner, &person) {
            self.audit(Entry {
                who: vec![person.clone()],
                tool: "prompt".into(),
                what: format!("message {}", message.id),
                decision: "deny".into(),
                by: Some("cap".into()),
                ..Entry::default()
            });
            self.answer_message(target, message, "cap", &format!("Not run: {why}."));
            return Admit::Answered;
        }
        if agent_sent {
            if let Some(ctx) = self.rights.as_mut() {
                ctx.authors
                    .insert(message.id.clone(), AGENT_SENT.to_owned());
            }
            return Admit::Queue { lifts_floor: false };
        }
        if let Some(ctx) = self.rights.as_mut() {
            ctx.authors.insert(message.id.clone(), person.clone());
        }
        Admit::Queue {
            lifts_floor: !owner_msg && rights.lifts_floor(&owner, std::slice::from_ref(&person)),
        }
    }

    /// Posts `text` as the Chief's reply to `message`.
    fn answer_message(&mut self, target: Option<&str>, message: &Message, kind: &str, text: &str) {
        let Some(conversation) = target
            .map(str::to_owned)
            .or_else(|| self.state.conversation.clone())
        else {
            return;
        };
        let mut entry = super::answer_entry(
            conversation,
            &format!("{kind}-{}", message.id),
            text,
            vec![message.id.clone()],
            Vec::new(),
        );
        if let Op::MessageSend { reply_to, .. } = &mut entry.op {
            *reply_to = Some(cmux_conversation::PartRef {
                message_id: message.id.clone(),
                part_index: 0,
            });
        }
        self.state.outbox.push(entry);
        self.save();
        self.flush_outbox();
    }

    /// USD spent today (local day) by `person` (None: every turn), from the
    /// audit's `spend` records.
    fn spent_today(&self, person: Option<&str>) -> f64 {
        let Some(ctx) = &self.rights else { return 0.0 };
        let Ok(records) = audit::read(&ctx.root) else {
            return 0.0;
        };
        let start = chrono::Local::now()
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .and_then(|t| t.and_local_timezone(chrono::Local).earliest())
            .map(|t| t.timestamp_millis())
            .unwrap_or(0);
        records
            .iter()
            .filter(|r| r.at >= start && r.entry.decision == "spend")
            .filter(|r| person.is_none_or(|p| r.entry.who.iter().any(|w| w == p)))
            .filter_map(|r| r.entry.usd)
            .sum()
    }

    /// Why `person` may not start a turn now for spend, if so.
    fn over_cap(&self, rights: &Rights, owner: &str, person: &str) -> Option<String> {
        if let Some(cap) = rights.chief_cap_usd_day {
            let spent = self.spent_today(None);
            if spent >= cap {
                return Some(format!(
                    "this Chief's daily cap of ${cap:.2} is reached (${spent:.2} spent today); its owner can raise it with /cap"
                ));
            }
        }
        if person == owner {
            return None;
        }
        let cap = rights.person(person).and_then(|p| p.cap_usd_day)?;
        let spent = self.spent_today(Some(person));
        (spent >= cap).then(|| {
            format!(
                "{}'s daily cap of ${cap:.2} on this Chief is reached (${spent:.2} spent today)",
                rights.name_of(person)
            )
        })
    }

    /// A chat command, answered by the host; None: not a command (the text
    /// goes to the Chief as written).
    fn command(
        &mut self,
        rights: &Rights,
        summary: &Summary,
        person: &str,
        owner_msg: bool,
        text: &str,
        message_id: &str,
    ) -> Option<String> {
        let owned = crate::rights::command_words(text);
        let words: Vec<&str> = owned.iter().map(String::as_str).collect();
        let verb = words.first()?.trim_start_matches('/');
        let args = &words[1..];
        let root = self.rights.as_ref()?.root.clone();
        let resolve = |w: &str| resolve_person(summary, rights, w);
        let owner_only = |s: &str| -> Option<String> {
            Some(if owner_msg {
                s.to_owned()
            } else {
                "Only this Chief's owner can change its rights.".into()
            })
        };
        let detected = self.rights.as_ref().and_then(|c| c.detected);
        match verb {
            "audit" => {
                let mut n = 20usize;
                let mut who: Option<String> = None;
                for a in args {
                    match a.parse::<usize>() {
                        Ok(k) => n = k.clamp(1, 200),
                        Err(_) if *a == "verify" => {
                            return Some(match audit::verify(&root) {
                                Ok(v) => match v.broken {
                                    None => format!(
                                        "Audit chain holds: {} records, head {}.",
                                        v.records,
                                        &v.head[..16]
                                    ),
                                    Some((line, why)) => {
                                        format!("Audit chain BROKEN at record {line}: {why}.")
                                    }
                                },
                                Err(e) => format!("Audit unreadable: {e}"),
                            });
                        }
                        Err(_) => who = Some(resolve(a)),
                    }
                }
                // Someone else sees their own records only.
                let full = owner_msg || rights.is_approver(person);
                if !full {
                    who = Some(person.to_owned());
                }
                let records = match audit::read(&root) {
                    Ok(r) => r,
                    Err(e) => return Some(format!("Audit unreadable: {e}")),
                };
                // The answer is a message everyone here reads: only records
                // of people present, and in a shared conversation none that
                // are the owner's alone (the owner reads those in a 1:1 or
                // with `optchat-chief audit`).
                // Everyone here reads the answer, so a record is shown only
                // when every reader may see it: the owner and approvers see
                // everything, anyone else (a Chief included) only records
                // that name them. With such readers present, a record must
                // name every one of them.
                let owner = self.settings.membership.owner.clone();
                let me = format!(
                    "{}{}",
                    crate::rights::CHIEF_PREFIX,
                    self.settings.membership.participant
                );
                let readers: Vec<String> = present_people(summary, &owner)
                    .into_iter()
                    .filter(|p| {
                        *p != owner
                            && *p != me
                            && (p.starts_with(crate::rights::CHIEF_PREFIX)
                                || !rights.is_approver(p))
                    })
                    .collect();
                let visible: Vec<audit::Record> = records
                    .into_iter()
                    .filter(|r| readers.iter().all(|u| r.entry.who.contains(u)))
                    .collect();
                let name_of = |id: &str| rights.name_of(id).to_owned();
                let mut lines: Vec<String> = audit::query(&visible, who.as_deref(), n)
                    .iter()
                    .map(|r| audit::line(r, &name_of))
                    .collect();
                if lines.is_empty() {
                    lines.push("No audit records yet.".into());
                }
                let (count, head) = audit::head(&root).unwrap_or((0, audit::GENESIS.into()));
                lines.push(format!("{count} records, head {}", &head[..16]));
                Some(lines.join("\n"))
            }
            "rights" => Some(crate::rights::render_with(
                rights,
                rights.auth_kind(detected),
            )),
            "grant" | "revoke" | "approver" | "cap" | "auth" if !owner_msg => owner_only(""),
            "grant" | "revoke" | "approver" | "cap" | "auth" => {
                let mut cli: Vec<String> = vec![verb.to_owned()];
                match (verb, args) {
                    ("cap", [amount]) => {
                        cli = vec!["chief-cap".into(), amount.to_string()];
                    }
                    ("auth", rest) => cli.extend(rest.iter().map(|s| s.to_string())),
                    (_, [who, rest @ ..]) => {
                        cli.push(resolve(who));
                        cli.extend(rest.iter().map(|s| s.to_string()));
                    }
                    _ => return Some(format!("usage: /{verb} {}", usage_of(verb))),
                }
                // A change runs once per message: a message read again after a
                // restart (its floor not yet saved) finds its record and
                // changes nothing, so it never undoes a later change.
                let via = format!("chat:{message_id}");
                if audit::read(&root).is_ok_and(|rs| {
                    rs.iter()
                        .any(|r| r.entry.via.as_deref() == Some(via.as_str()))
                }) {
                    return Some(format!("/{verb}: done already."));
                }
                let owner = self.settings.membership.owner.clone();
                let answer = match crate::rights::run_as(&cli, &root, &owner, person, &via) {
                    Ok(done) => done,
                    Err(e) => return Some(format!("/{verb}: {e}")),
                };
                Some(answer)
            }
            _ => None,
        }
    }

    /// The people of a turn about to run `items`: the persons behind its
    /// messages, plus [`UNKNOWN`] for a gated item no message names.
    pub(super) fn begin_turn_people(&mut self, items: &[super::Queued], key: &str) {
        let Some(ctx) = self.rights.as_mut() else {
            return;
        };
        ctx.turn_people.clear();
        ctx.turn_key = Some(key.to_owned());
        self.add_turn_people(items);
        self.forget_authors(items);
        let owner = self.settings.membership.owner.clone();
        if let Some(ctx) = self.rights.as_mut()
            && ctx.turn_people.is_empty()
        {
            ctx.turn_people.push(owner);
            if let Some(key) = &ctx.turn_key {
                save_turn_people(&ctx.root, key, &ctx.turn_people);
            }
        }
    }

    /// Adds the people of `items` (steered into the running turn, or its
    /// opening) to the turn's.
    pub(super) fn add_turn_people(&mut self, items: &[super::Queued]) {
        let owner = self.settings.membership.owner.clone();
        let Some(ctx) = self.rights.as_mut() else {
            return;
        };
        let mut people: Vec<String> = std::mem::take(&mut ctx.turn_people);
        for item in items {
            let who = match &item.source {
                super::Source::Message {
                    id,
                    requires_approval,
                    ..
                } => match ctx.authors.get(id) {
                    Some(p) => Some(p.clone()),
                    None if *requires_approval => Some(UNKNOWN.to_owned()),
                    None => Some(owner.clone()),
                },
                super::Source::Peer { from } => {
                    Some(format!("{}{from}", crate::rights::CHIEF_PREFIX))
                }
                _ if item.requires_approval() => Some(UNKNOWN.to_owned()),
                _ => None,
            };
            if let Some(who) = who
                && !people.contains(&who)
            {
                people.push(who);
            }
        }
        ctx.turn_people = people;
        if let Some(key) = &ctx.turn_key {
            save_turn_people(&ctx.root, key, &ctx.turn_people);
        }
    }

    /// Forgets the authors of `items` once they are in the turn for good
    /// (started or delivered).
    pub(super) fn forget_authors(&mut self, items: &[super::Queued]) {
        let Some(ctx) = self.rights.as_mut() else {
            return;
        };
        for item in items {
            if let super::Source::Message { id, .. } = &item.source {
                ctx.authors.remove(id);
            }
        }
    }

    /// Audits the ended turn's cost against its people.
    pub(super) fn end_turn_spend(&mut self, usd: Option<f64>) {
        let Some(ctx) = self.rights.as_mut() else {
            return;
        };
        let people = std::mem::take(&mut ctx.turn_people);
        let key = ctx.turn_key.take();
        let Some(usd) = usd.filter(|u| *u > 0.0) else {
            return;
        };
        self.audit(Entry {
            who: people,
            via: key,
            tool: "turn".into(),
            what: format!("a turn costing ${usd:.4}"),
            decision: "spend".into(),
            usd: Some(usd),
            ..Entry::default()
        });
    }

    /// The turn hook's question (`optchat-chief rights-hook`): `phase` is
    /// `pre` or `post`, `payload` Claude Code's hook input. Answers the JSON
    /// the hook prints (empty object: no decision).
    pub fn rights_hook(&mut self, phase: &str, payload: &Value) -> Value {
        let Some(ctx) = self.rights.clone() else {
            return json!({});
        };
        let tool = payload
            .get("tool_name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let input = payload.get("tool_input");
        let owner = self.settings.membership.owner.clone();
        // The turn's people as this host recorded them; after a restart, as
        // the last host saved them for the same turn; else nobody known, and
        // every call outside the Chief's own tools is refused (fail closed).
        let current = self.state.turn.as_ref().map(|t| t.key.clone());
        let people = if !ctx.turn_people.is_empty() {
            ctx.turn_people.clone()
        } else {
            // A turn this host did not start (one it adopted after a
            // restart, or one that outlived its outcome) is the saved one.
            match (current.as_deref(), load_turn_people(&ctx.root)) {
                (key, Some((saved, people)))
                    if key.is_none_or(|k| k == saved) && !people.is_empty() =>
                {
                    if let Some(c) = self.rights.as_mut() {
                        c.turn_people = people.clone();
                        c.turn_key = Some(saved);
                    }
                    people
                }
                _ => vec![UNKNOWN.to_owned()],
            }
        };
        let ctx = self.rights.clone().unwrap_or(ctx);
        let what = crate::approval::describe(&tool, input);
        let input_sha = input.map(|i| audit::sha256(i.to_string().as_bytes()));
        let cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if phase == "post" {
            let output = payload.get("tool_response").map(|r| match r {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            });
            self.audit(Entry {
                who: people,
                via: ctx.turn_key.clone(),
                cwd,
                tool,
                what,
                input_sha256: input_sha,
                decision: "result".into(),
                output_sha256: output.as_ref().map(|o| audit::sha256(o.as_bytes())),
                output_bytes: output.as_ref().map(|o| o.len() as u64),
                ..Entry::default()
            });
            return json!({});
        }
        // The memory tools and the Chief's own tools keep their own rules:
        // the turn's settings allow them and `turn_gate` checks their
        // arguments (README "Remote-origin messages"). The hook audits them
        // and gives no decision.
        if crate::approval::MEMORY_TOOLS.contains(&tool.as_str())
            || crate::approval::CHIEF_TOOLS.contains(&tool.as_str())
        {
            self.audit(Entry {
                who: people,
                via: ctx.turn_key.clone(),
                cwd,
                tool,
                what,
                input_sha256: input_sha,
                decision: "pass".into(),
                by: Some("chief tool: its arguments are checked when it runs".into()),
                ..Entry::default()
            });
            return json!({});
        }
        let rights = self.rights_table();
        let protected = vec![ctx.root.clone()];
        let decision = rights.decide(&owner, &people, &tool, input, &protected);
        let gated = self.turn_ask || self.last_turn_ask;
        let (label, answer) = match (&decision, gated) {
            // The owner's (or an approver's) turn: its own policy decides.
            (Decision::Allow(_), false) => ("allow".to_owned(), json!({})),
            (Decision::Allow(_), true) => (
                "allow".to_owned(),
                json!({"hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": format!("allowed by the rights table ({})", decision.by()),
                }}),
            ),
            (Decision::Deny { who, why }, _) => {
                // Counted like a refused permission request: a model that
                // keeps asking for it is stopped.
                if gated {
                    self.count_denial(&tool, input, super::approvals::DenyWhy::OtherPerson);
                }
                (
                    "deny".to_owned(),
                    json!({"hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": format!("refused: {}: {why}", rights.name_of(who)),
                    }}),
                )
            }
        };
        self.audit(Entry {
            who: people,
            via: ctx.turn_key.clone(),
            cwd,
            tool,
            what,
            input_sha256: input_sha,
            decision: label,
            by: Some(match &decision {
                Decision::Deny { who, why } => format!("{who}: {why}"),
                d => d.by(),
            }),
            ..Entry::default()
        });
        answer
    }

    /// A message from another person's Chief through the agent hub
    /// (`[chief:<name>] <text>`, peer_chiefs.rs). With the rights table on it
    /// is that Chief's request: stamped with the person it acts for (the
    /// owner's own word in the table, never the request's), run under the
    /// floor with `chief:<name>`'s grants, and only on a login that may serve
    /// it ([`Rights::may_prompt`]) and under the caps. Without the table it is
    /// a work note, as before.
    pub(super) fn peer_chief_note(&mut self, text: String) {
        let from = text
            .strip_prefix("[chief:")
            .and_then(|rest| rest.split_once(']'))
            .map(|(name, _)| name.to_owned())
            .filter(|n| !n.is_empty() && !n.contains(char::is_whitespace));
        let from = match from {
            Some(from) if self.rights.is_some() => from,
            _ => {
                self.queue(text, super::Source::Note);
                return;
            }
        };
        let person = format!("{}{from}", crate::rights::CHIEF_PREFIX);
        let owner = self.settings.membership.owner.clone();
        let rights = self.rights_table();
        let detected = self.rights.as_ref().and_then(|c| c.detected);
        let refused = rights
            .may_prompt(&owner, &person, detected)
            .err()
            .or_else(|| self.over_cap(&rights, &owner, &person));
        if let Some(why) = refused {
            self.audit(Entry {
                who: vec![person.clone()],
                tool: "prompt".into(),
                what: "a request from another person's Chief".into(),
                input_sha256: Some(audit::sha256(text.as_bytes())),
                decision: "deny".into(),
                by: Some(why.clone()),
                ..Entry::default()
            });
            (self.log)(&format!("{person}'s request not run: {why}"));
            // The owner hears of it as a note (no turn runs on it).
            if let Err(e) = self.chat.append(
                optchat_core::Kind::Note,
                &format!("{person} asked something; not run: {why}"),
            ) {
                (self.log)(&format!("logging the refusal failed: {e}"));
            }
            return;
        }
        let acting_for = rights
            .person(&person)
            .and_then(|p| p.owner.as_deref())
            .map(|o| rights.name_of(o).to_owned());
        let stamped = match acting_for {
            Some(o) => text.replacen(
                &format!("[chief:{from}]"),
                &format!("[chief:{from}, the Chief of {o}; another person's Chief: answer it with tell(\"chief:{from}\")]"),
                1,
            ),
            None => text.replacen(
                &format!("[chief:{from}]"),
                &format!("[chief:{from}; another person's Chief: answer it with tell(\"chief:{from}\")]"),
                1,
            ),
        };
        self.queue(stamped, super::Source::Peer { from });
    }

    /// Whether the running turn's people include `person` (a `tell` back to
    /// the Chief that asked is allowed in its own turn).
    pub(super) fn turn_has_person(&self, person: &str) -> bool {
        self.rights
            .as_ref()
            .is_some_and(|c| c.turn_people.iter().any(|p| p == person))
    }

    /// Audits a refusal the host made itself (approvals.rs).
    pub(super) fn audit_refusal(&self, tool: &str, input: Option<&Value>, approver: &str) {
        let Some(ctx) = &self.rights else { return };
        self.audit(Entry {
            who: ctx.turn_people.clone(),
            via: ctx.turn_key.clone(),
            tool: tool.to_owned(),
            what: crate::approval::describe(tool, input),
            input_sha256: input.map(|i| audit::sha256(i.to_string().as_bytes())),
            decision: "deny".into(),
            by: Some(approver.to_owned()),
            ..Entry::default()
        });
    }
}

/// The running turn's people, saved so a host that restarts mid-turn still
/// holds the turn's tool calls to them (`rights-turn.json`, 0600).
fn save_turn_people(root: &std::path::Path, key: &str, people: &[String]) {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let path = root.join("rights-turn.json");
    let tmp = root.join(format!("rights-turn.json.{}.tmp", std::process::id()));
    let body = json!({"turn": key, "people": people}).to_string();
    let ok = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .and_then(|mut f| f.write_all(body.as_bytes()))
        .and_then(|_| std::fs::rename(&tmp, &path));
    if ok.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

fn load_turn_people(root: &std::path::Path) -> Option<(String, Vec<String>)> {
    let v: Value =
        serde_json::from_str(&std::fs::read_to_string(root.join("rights-turn.json")).ok()?).ok()?;
    let key = v.get("turn")?.as_str()?.to_owned();
    let people = v
        .get("people")?
        .as_array()?
        .iter()
        .filter_map(|p| p.as_str().map(str::to_owned))
        .collect();
    Some((key, people))
}

fn usage_of(verb: &str) -> &'static str {
    match verb {
        "grant" => "PERSON PATTERN... (e.g. /grant @Ben Read Bash(git status*))",
        "revoke" => "PERSON [PATTERN...]",
        "approver" => "PERSON on|off",
        "cap" => "USD|off (the Chief) or /cap PERSON USD|off",
        "auth" => "api-key|bedrock|vertex|foundry|team|enterprise|personal|auto",
        _ => "",
    }
}

/// The people of a conversation as the rights table names them: the owner
/// (themself or a paired device), other humans by person or id, Chiefs as
/// `chief:<id>`.
fn present_people(summary: &Summary, owner: &str) -> Vec<String> {
    summary
        .participants
        .iter()
        .map(|p| match p.kind {
            cmux_conversation::ParticipantKind::Agent => {
                format!("{}{}", crate::rights::CHIEF_PREFIX, p.id)
            }
            _ if p.id == owner || p.person.as_deref() == Some(owner) => owner.to_owned(),
            _ => p.person.clone().unwrap_or_else(|| p.id.clone()),
        })
        .collect()
}

/// A participant's display name.
fn display_name(summary: &Summary, id: &str) -> String {
    summary
        .participants
        .iter()
        .find(|p| p.id == id)
        .map(|p| p.display_name.clone())
        .unwrap_or_else(|| id.to_owned())
}

/// `@Ben`, `Ben`, `user_ben` or `chief:x` as a person id: a participant
/// whose id or display name matches (case-insensitive), else a table entry
/// whose name matches, else the word as written.
fn resolve_person(summary: &Summary, rights: &Rights, word: &str) -> String {
    let w = word.trim_start_matches('@');
    if let Some(p) = summary
        .participants
        .iter()
        .find(|p| p.id == w || p.display_name.eq_ignore_ascii_case(w))
    {
        if p.kind == cmux_conversation::ParticipantKind::Agent {
            return format!("{}{}", crate::rights::CHIEF_PREFIX, p.id);
        }
        return p.person.clone().unwrap_or_else(|| p.id.clone());
    }
    if let Some((id, _)) = rights
        .people
        .iter()
        .find(|(id, p)| *id == w || p.name.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(w)))
    {
        return id.clone();
    }
    w.to_owned()
}
