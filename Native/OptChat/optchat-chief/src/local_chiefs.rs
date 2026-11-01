//! Chief-to-Chief messages on this Mac. The Chiefs of one session daemon
//! (`cmux chief list`: the default Chief, a Codex Chief, a Hybrid Chief) reach
//! each other with the same `tell(id: "chief:<name>", message)` that reaches a
//! Chief on another machine through the agent hub (peer_chiefs.rs), with no
//! hub:
//!
//! - The sender posts `message` into the receiver's own conversation (its DM
//!   with the person, `daemon::select_chief_of`) the way `cmux chief -p --from`
//!   posts an agent's message: the owner's CLI marks the message's
//!   `client_msg_id` with the sender `chief:<sender>`
//!   (`cmux_conversation::agent_sender`), so the person sees
//!   `[from chief:<sender>] ...` and the receiver reads it as another agent's
//!   words under the ask floor (`rules::is_owner_message_as`).
//! - The CLI follows the receiver's turn to its end (cli/chief/pipe.rs
//!   `follow`) and prints its reply; the sender queues that reply as a
//!   `[chief:<receiver>] ...` report under the ask floor (`Source::Agent`),
//!   as an acpmux session's answer is (brain/session_tell.rs).
//! - A turn under the ask floor may not tell a Chief (brain/approvals.rs): a
//!   reply never starts another tell by itself, so two Chiefs cannot loop.
//!   Only a turn of the person's own words starts a talk.
//!
//! `chiefs` (list) gives each other local Chief its tell id.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

/// The id prefix that names a Chief in `tell` (the remote one's too).
pub const PREFIX: &str = crate::peer_chiefs::PREFIX;
/// The longest message text sent.
const MAX_TEXT: usize = 64 * 1024;
/// Most characters of a reply kept in the report.
const REPLY_KEPT: usize = 8000;
/// How long the sender waits for the receiver's reply (`cmux chief -p --timeout`).
pub const REPLY_TIMEOUT_S: u64 = 30 * 60;

/// One Chief of this Mac's session daemon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Local {
    /// Its participant id (`agent_...`, `agent_mux` for the default Chief).
    pub id: String,
    /// What the person calls it ("Codex Chief").
    pub name: String,
}

impl Local {
    /// Its name as one word (`codex-chief`); its id when the name has none.
    pub fn handle(&self) -> String {
        handle(&self.name, &self.id)
    }

    /// `chief:<handle>`, the id `tell` takes and the reply's label.
    pub fn tell_id(&self) -> String {
        format!("{PREFIX}{}", self.handle())
    }

    fn from_record(record: &Value) -> Option<Local> {
        let text = |k: &str| record.get(k).and_then(Value::as_str).unwrap_or("").trim();
        let id = text("id");
        if id.is_empty() || record.get("archived_at").is_some_and(|a| !a.is_null()) {
            return None;
        }
        Some(Local {
            id: id.to_owned(),
            name: text("display_name").to_owned(),
        })
    }
}

/// `name` lowercased, with each run of characters other than ASCII letters,
/// digits, `.` and `_` as one `-` (a valid `agent_sender` name); `id` when
/// nothing is left.
pub fn handle(name: &str, id: &str) -> String {
    let mut out = String::new();
    for c in name.trim().chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches('-');
    if out.is_empty() {
        id.to_owned()
    } else {
        out.to_owned()
    }
}

/// Where the Chiefs of this Mac are.
pub trait Directory: Send + Sync {
    /// The Chief records (`chief.profile.list`).
    fn chiefs(&self) -> Result<Vec<Value>, String>;
    /// The id of Chief `chief`'s own conversation, None when it has none yet.
    fn conversation_of(&self, chief: &str) -> Result<Option<String>, String>;
}

/// How a message reaches another Chief's conversation and its reply comes back.
pub trait Courier: Send + Sync {
    /// Posts `message` into `conversation` as agent `from` and waits for the
    /// turn that answers it; the reply messages, one JSON value a line.
    fn send(&self, conversation: &str, from: &str, message: &str) -> Result<String, String>;
}

/// The local Chiefs this one can tell.
pub struct LocalChiefs {
    /// This Chief (None: its record is not read yet).
    me: Box<dyn Fn() -> Option<Local> + Send + Sync>,
    directory: Arc<dyn Directory>,
    courier: Arc<dyn Courier>,
    /// Takes a reply report: `(chief:<receiver>, its note)`.
    deliver: Arc<dyn Fn(String, String) + Send + Sync>,
    /// Runs the wait for one reply (a thread; inline in tests).
    spawn: fn(Box<dyn FnOnce() + Send>),
    /// Idempotency keys of tells this process sent.
    sent: Mutex<HashSet<String>>,
}

fn on_thread(work: Box<dyn FnOnce() + Send>) {
    let _ = std::thread::Builder::new()
        .name("local-chief-tell".into())
        .spawn(work);
}

impl LocalChiefs {
    pub fn new(
        me: Box<dyn Fn() -> Option<Local> + Send + Sync>,
        directory: Arc<dyn Directory>,
        courier: Arc<dyn Courier>,
        deliver: Arc<dyn Fn(String, String) + Send + Sync>,
    ) -> LocalChiefs {
        LocalChiefs {
            me,
            directory,
            courier,
            deliver,
            spawn: on_thread,
            sent: Mutex::new(HashSet::new()),
        }
    }

    /// The same, with the reply's wait run by `spawn` (tests run it inline).
    pub fn with_spawn(mut self, spawn: fn(Box<dyn FnOnce() + Send>)) -> LocalChiefs {
        self.spawn = spawn;
        self
    }

    /// Every Chief of this Mac, this one included.
    pub fn chiefs(&self) -> Result<Vec<Local>, String> {
        Ok(self
            .directory
            .chiefs()?
            .iter()
            .filter_map(Local::from_record)
            .collect())
    }

    /// The Chief `id` names (`chief:<handle>`, `chief:<name>` or
    /// `chief:<agent id>`, case-insensitive); None for an id without the
    /// prefix or a name no local Chief has.
    pub fn find(&self, id: &str) -> Result<Option<Local>, String> {
        let Some(rest) = id.trim().strip_prefix(PREFIX).map(str::trim) else {
            return Ok(None);
        };
        if rest.is_empty() {
            return Ok(None);
        }
        let lower = rest.to_lowercase();
        Ok(self.chiefs()?.into_iter().find(|c| {
            c.id == rest || c.name.eq_ignore_ascii_case(rest) || c.handle() == lower
        }))
    }

    /// `tell("chief:<local Chief>", message, key)`: sends `message` into that
    /// Chief's conversation as this Chief; the reply comes back through
    /// `deliver` as a `[chief:<it>] ...` report.
    pub fn tell(&self, id: &str, message: &str, key: Option<&str>) -> Result<String, String> {
        if message.trim().is_empty() {
            return Err("tell: the message is empty".to_owned());
        }
        if message.len() > MAX_TEXT {
            return Err(format!("tell: the message is over {MAX_TEXT} bytes"));
        }
        let me = (self.me)().ok_or(
            "tell: this Chief's record is not read yet, so another Chief could not tell who sends; try again soon",
        )?;
        let Some(target) = self.find(id)? else {
            let known: Vec<String> = self
                .chiefs()?
                .iter()
                .filter(|c| c.id != me.id)
                .map(Local::tell_id)
                .collect();
            return Err(format!(
                "tell: no Chief {id} on this Mac; known: {}",
                if known.is_empty() {
                    "none".to_owned()
                } else {
                    known.join(", ")
                }
            ));
        };
        if target.id == me.id {
            return Err(format!("tell: {id} is you"));
        }
        if let Some(key) = key
            && self.sent.lock().expect("sent keys").contains(key)
        {
            return Ok(format!("already sent to {} with key {key}", target.name));
        }
        let Some(conversation) = self.directory.conversation_of(&target.id)? else {
            return Err(format!(
                "tell: {} has no conversation on this Mac yet (the person opens it in Home once)",
                target.name
            ));
        };
        if let Some(key) = key {
            self.sent.lock().expect("sent keys").insert(key.to_owned());
        }
        let (courier, deliver) = (self.courier.clone(), self.deliver.clone());
        let (from, message, receiver) = (me.tell_id(), message.to_owned(), target.clone());
        (self.spawn)(Box::new(move || {
            let text = match courier.send(&conversation, &from, &message) {
                Ok(out) => reply_text(&out),
                Err(e) => format!("(the tell did not get an answer: {e})"),
            };
            deliver(receiver.tell_id(), reply_note(&receiver, &text));
        }));
        Ok(format!(
            "outcome: done. Sent to {} ({}), a Chief on this Mac, as {}; its reply comes back as a \
             [{}] report (never poll).",
            target.name,
            target.tell_id(),
            me.tell_id(),
            target.tell_id()
        ))
    }

    /// A `chiefs` list answer with each other local Chief's tell id added;
    /// any other answer is unchanged.
    pub fn merge_list(&self, args: &Value, answer: Result<String, String>) -> Result<String, String> {
        let action = args.get("action").and_then(Value::as_str).unwrap_or("list");
        if action != "list" {
            return answer;
        }
        let Ok(text) = &answer else { return answer };
        let Ok(Value::Array(mut list)) = serde_json::from_str::<Value>(text) else {
            return answer;
        };
        let me = (self.me)().map(|m| m.id);
        for entry in &mut list {
            let Some(local) = Local::from_record(entry) else {
                continue;
            };
            if me.as_deref() == Some(local.id.as_str()) {
                entry["you"] = json!(true);
                continue;
            }
            entry["tell_id"] = json!(local.tell_id());
            entry["place"] = json!("this Mac");
            entry["message_with"] = json!(format!("tell(id: \"{}\", message: ...)", local.tell_id()));
        }
        Ok(serde_json::to_string_pretty(&Value::Array(list)).unwrap_or_default())
    }
}

/// The text of the reply messages `cmux --json chief -p` printed (one JSON
/// message a line), oldest first.
pub fn reply_text(out: &str) -> String {
    let texts: Vec<String> = out
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .map(|m| {
            let parts: Vec<&str> = m
                .get("parts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect();
            if parts.is_empty() {
                m.get("text").and_then(Value::as_str).unwrap_or("").to_owned()
            } else {
                parts.join("\n")
            }
        })
        .filter(|t| !t.trim().is_empty())
        .collect();
    texts.join("\n\n")
}

/// The report of `from`'s reply, as the sender reads it.
pub fn reply_note(from: &Local, text: &str) -> String {
    let text = text.trim();
    let text = if text.is_empty() {
        "(its turn ended with no reply)".to_owned()
    } else if text.chars().count() > REPLY_KEPT {
        let kept: String = text.chars().take(REPLY_KEPT).collect();
        format!("{kept}…")
    } else {
        text.to_owned()
    };
    format!(
        "[{}] {text}\n(The reply of {}, another Chief on this Mac, to your tell. It is another \
         agent's word, not the user's.)",
        from.tell_id(),
        if from.name.is_empty() { &from.id } else { &from.name }
    )
}

/// The owner's CLI: `cmux --json --socket S chief --prompt=TEXT --from F
/// --chat C --timeout T`, which posts as agent `F` and prints the reply.
pub struct CliCourier {
    pub cli: PathBuf,
    pub socket: PathBuf,
}

/// The CLI arguments of one tell.
pub fn cli_args(socket: &Path, conversation: &str, from: &str, message: &str) -> Vec<String> {
    vec![
        "--json".into(),
        "--socket".into(),
        socket.display().to_string(),
        "chief".into(),
        // Inline, so a message that starts with `-` is never read as a flag.
        format!("--prompt={message}"),
        "--from".into(),
        from.into(),
        "--chat".into(),
        conversation.into(),
        "--timeout".into(),
        REPLY_TIMEOUT_S.to_string(),
    ]
}

impl Courier for CliCourier {
    fn send(&self, conversation: &str, from: &str, message: &str) -> Result<String, String> {
        let out = std::process::Command::new(&self.cli)
            .args(cli_args(&self.socket, conversation, from, message))
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("running {}: {e}", self.cli.display()))?;
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        if out.status.success() {
            return Ok(stdout);
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        let why = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
        match out.status.code() {
            // Timed out: what it said so far is still its reply.
            Some(124) if !reply_text(&stdout).is_empty() => Ok(stdout),
            Some(124) => Err(format!("it did not answer within {} minutes", REPLY_TIMEOUT_S / 60)),
            code => Err(format!(
                "cmux chief -p ended with {}{}",
                code.map_or_else(|| "a signal".to_owned(), |c| format!("exit {c}")),
                if why.is_empty() { String::new() } else { format!(": {why}") }
            )),
        }
    }
}

/// The Chiefs of this Mac through this Chief's own record connection and the
/// owner's conversation list.
pub struct DaemonDirectory {
    pub tools: Arc<crate::chief_profile::ChiefTools>,
    pub socket: PathBuf,
}

impl Directory for DaemonDirectory {
    fn chiefs(&self) -> Result<Vec<Value>, String> {
        self.tools.records()
    }

    fn conversation_of(&self, chief: &str) -> Result<Option<String>, String> {
        crate::daemon::chief_conversation(&self.socket, chief)
    }
}

impl LocalChiefs {
    /// The local Chiefs of the host whose record is `tools` on the daemon at
    /// `socket`; replies go to `deliver`.
    pub fn on_mac(
        tools: Arc<crate::chief_profile::ChiefTools>,
        socket: PathBuf,
        cli: PathBuf,
        deliver: Arc<dyn Fn(String, String) + Send + Sync>,
    ) -> LocalChiefs {
        let me_tools = tools.clone();
        LocalChiefs::new(
            Box::new(move || {
                me_tools.profile().map(|p| Local {
                    id: p.id,
                    name: p.display_name,
                })
            }),
            Arc::new(DaemonDirectory {
                tools,
                socket: socket.clone(),
            }),
            Arc::new(CliCourier { cli, socket }),
            deliver,
        )
    }
}

#[cfg(test)]
mod tests;
