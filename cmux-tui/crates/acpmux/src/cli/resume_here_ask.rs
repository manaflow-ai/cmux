//! `acpmux resume-here`'s permission prompt (Toggle Terminal and Chat, Leo 2026-11-12: two live
//! views of one session, instant both ways). The terminal waits for the chat's turn to end
//! (`resume_here.rs`); a permission the turn asks for keeps it waiting (`release_to_watch.rs`
//! counts a pending one as busy), so the terminal shows it and takes the answer:
//!
//! - The chat's pending permission prints as its title, the command it runs, and its options
//!   numbered; a number and Enter answers it (the terminal is in cooked mode). One already pending
//!   when the terminal opens shows at once.
//! - The daemon still decides who may answer what (`hub/person.rs`): only the cmux app may allow,
//!   so an allow picked here is refused and says to switch the pane to Chat; a deny answers here.
//! - One answered in the chat (or withdrawn) is no longer asked here, and the next one shows.
//!
//! It reads on a connection of its own: a hold attach for the session's permission records
//! (`hold: true`, no history read), and `_acpmux/info`'s `pending` list after each one, so what it
//! asks is always the daemon's pending prompt, never a guess from the stream. Stdin is read only
//! while a question is up: whatever the person types before then stays for the harness's resume.

use crate::client::Client;
use crate::rpc::{Message, method};
use anyhow::Result;
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::{mpsc, watch};

/// The permission records that change what is pending (`hub/permissions`, `hub/hosts.rs`).
const KINDS: &[&str] = &[
    "permission_request",
    "permission_reissued",
    "permission_decision",
    "permission_auto",
    "permission_withdrawn",
];

/// One option of a pending permission, as the agent offered it.
#[derive(Clone, Debug, PartialEq)]
struct Choice {
    id: String,
    name: String,
    kind: String,
}

impl Choice {
    fn allows(&self) -> bool {
        self.kind.starts_with("allow")
    }
}

/// The permission the terminal asks about.
#[derive(Clone, Debug, PartialEq)]
struct Asked {
    permission_id: String,
    choices: Vec<Choice>,
    /// An agent question (`question_answer.rs`): answered in the chat, never by a number.
    question: bool,
}

/// What the terminal asks and what it sent: the state of one session's prompt here.
#[derive(Debug, Default)]
pub struct Ask {
    asked: Option<Asked>,
    /// The permission and the option name this terminal answered with.
    sent: Option<(String, String)>,
}

/// An answer to send: `_acpmux/permission_respond`'s params.
#[derive(Debug, PartialEq)]
pub struct Answer {
    pub permission_id: String,
    pub option_id: String,
}

impl Ask {
    /// The chat's pending permissions now (`_acpmux/info` `pending`, oldest first): what to print
    /// when what the terminal asks changed, else None.
    pub fn pending(&mut self, pending: &[Value]) -> Option<String> {
        let id_of = |p: &Value| p.get("permissionId").and_then(Value::as_str).map(str::to_owned);
        let mut text = String::new();
        if let Some(asked) = &self.asked {
            if pending.iter().any(|p| id_of(p).as_deref() == Some(asked.permission_id.as_str())) {
                return None;
            }
            text = match self.sent.take() {
                Some((pid, name)) if pid == asked.permission_id => format!("answered: {name}\n"),
                _ => "answered in the chat\n".to_owned(),
            };
            self.asked = None;
        }
        if let Some(next) = pending.iter().find(|p| id_of(p).is_some()) {
            let request = next.get("request").unwrap_or(&Value::Null);
            let asked = Asked {
                permission_id: id_of(next).unwrap_or_default(),
                choices: choices(request),
                question: crate::question_answer::question(request).is_some(),
            };
            text.push_str(&show(request, &asked));
            self.asked = Some(asked);
        }
        (!text.is_empty()).then_some(text)
    }

    /// A number can answer what is shown now.
    pub fn asking(&self) -> bool {
        self.asked.as_ref().is_some_and(|a| !a.question && !a.choices.is_empty())
    }

    /// A line the person typed: the answer it picks, or what to print instead.
    pub fn pick(&mut self, line: &str) -> Result<Answer, String> {
        let Some(asked) = self.asked.as_ref().filter(|_| self.asking()) else {
            return Err(String::new());
        };
        let n = asked.choices.len();
        let picked = line.trim().parse::<usize>().ok().filter(|i| (1..=n).contains(i));
        let Some(choice) = picked.and_then(|i| asked.choices.get(i.checked_sub(1)?)) else {
            return Err(format!("type a number from 1 to {n} and Enter\n"));
        };
        self.sent = Some((asked.permission_id.clone(), choice.name.clone()));
        Ok(Answer { permission_id: asked.permission_id.clone(), option_id: choice.id.clone() })
    }

    /// The daemon refused the answer [`pick`](Self::pick) made: what to print. The question
    /// stays up.
    pub fn refused(&mut self, error: &anyhow::Error) -> String {
        self.sent = None;
        let person = error.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| {
            d.0.data.as_ref().and_then(|v| v.get("reason")).and_then(Value::as_str)
                == Some(crate::hub::person::REASON)
        });
        if person {
            "only the cmux app can allow: switch this pane to Chat to allow it, or pick a deny \
             here\n"
                .to_owned()
        } else {
            format!("could not answer: {error:#}\n")
        }
    }
}

fn choices(request: &Value) -> Vec<Choice> {
    let text = |o: &Value, k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    request
        .get("options")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .map(|o| Choice {
                    id: text(o, "optionId"),
                    name: text(o, "name"),
                    kind: text(o, "kind"),
                })
                .filter(|c| !c.id.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// The question as the terminal prints it.
fn show(request: &Value, asked: &Asked) -> String {
    let title = request.pointer("/toolCall/title").and_then(Value::as_str).unwrap_or("permission");
    let mut text = format!("\x1b[33mpermission needed:\x1b[0m {title}\n");
    let command = match request.pointer("/toolCall/rawInput/command") {
        Some(Value::String(c)) => Some(c.clone()),
        Some(Value::Array(words)) => {
            Some(words.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        }
        _ => None,
    };
    if let Some(command) = command.filter(|c| !c.is_empty() && c != title) {
        for line in command.lines() {
            text.push_str(&format!("    {line}\n"));
        }
    }
    if asked.question {
        text.push_str(
            "the agent asks a question: answer it in the chat (switch this pane to Chat)\n",
        );
        return text;
    }
    for (i, c) in asked.choices.iter().enumerate() {
        text.push_str(&format!("  {}. {}\n", i + 1, c.name));
    }
    if asked.choices.is_empty() {
        return text;
    }
    let allows: Vec<String> = asked
        .choices
        .iter()
        .enumerate()
        .filter(|(_, c)| c.allows())
        .map(|(i, _)| (i + 1).to_string())
        .collect();
    text.push_str("type a number and Enter");
    if !allows.is_empty() {
        let which = allows.join(", ");
        text.push_str(&format!(
            "; only the cmux app can allow ({which}): switch this pane to Chat for that"
        ));
    }
    text.push('\n');
    text
}

/// Follows `id`'s pending permissions on `client` (a connection of this terminal's own): prints
/// each change to `out`, takes the person's lines from `lines` and answers. `asking` says when a
/// line can answer, so stdin is read only then. Ends when the connection does.
pub async fn follow(
    client: Arc<Client>,
    id: &str,
    mut lines: mpsc::Receiver<String>,
    asking: watch::Sender<bool>,
    out: mpsc::UnboundedSender<String>,
) -> Result<()> {
    let mut notes = client
        .notifications()
        .await
        .ok_or_else(|| anyhow::anyhow!("notifications already taken"))?;
    let attached = client
        .request(
            method::MUX_ATTACH,
            json!({"sessionId": id, "hold": true, "eventStream": true, "kinds": KINDS,
                   "visible": false}),
        )
        .await?;
    let mut ask = Ask::default();
    let said = |ask: &mut Ask, pending: &[Value]| {
        if let Some(text) = ask.pending(pending) {
            let _ = out.send(text);
        }
        let _ = asking.send(ask.asking());
    };
    said(&mut ask, &pending_of(attached.pointer("/session/pending")));
    loop {
        tokio::select! {
            note = notes.recv() => {
                let Some(note) = note else { return Ok(()) };
                let Message::Notification { method: m, params } = note else { continue };
                if m == method::MUX_DISCONNECTED {
                    return Ok(());
                }
                let p = params.unwrap_or(Value::Null);
                let mine = crate::cli::resolve::routed_id(&p).ok().as_deref() == Some(id);
                // The attach's own records; its `permission_pending` beside each ask says the same.
                let changes = m == method::MUX_EVENT
                    && p.get("kind").and_then(Value::as_str).is_some_and(|k| KINDS.contains(&k));
                if mine && changes {
                    let info = client.request(method::MUX_INFO, json!({"sessionId": id})).await?;
                    said(&mut ask, &pending_of(info.get("pending")));
                }
            }
            line = lines.recv() => {
                let Some(line) = line else { return Ok(()) };
                match ask.pick(&line) {
                    Ok(answer) => {
                        let sent = client
                            .request(
                                method::MUX_PERMISSION_RESPOND,
                                json!({"sessionId": id, "permissionId": answer.permission_id,
                                       "optionId": answer.option_id}),
                            )
                            .await;
                        if let Err(e) = sent {
                            let _ = out.send(ask.refused(&e));
                        }
                    }
                    Err(text) if !text.is_empty() => {
                        let _ = out.send(text);
                    }
                    Err(_) => {}
                }
            }
        }
    }
}

fn pending_of(v: Option<&Value>) -> Vec<Value> {
    v.and_then(Value::as_array).cloned().unwrap_or_default()
}

/// Runs [`follow`] for this terminal while it waits, when stdin is a terminal: prints to stdout
/// and reads stdin's lines only while a question is up. Its tasks are its scope's: [`Prompt::end`]
/// cancels and joins them; a drop without it cancels them.
pub(crate) struct Prompt(Option<cmux_scope::Scope>);

impl Prompt {
    /// Stops the prompt and waits for its tasks (a stdin read ends within its 250 ms poll).
    pub(crate) async fn end(mut self) {
        if let Some(scope) = self.0.take() {
            let _ = scope.close(std::time::Duration::from_millis(500)).await;
        }
    }
}

pub(crate) fn start(id: &str) -> Prompt {
    use std::io::IsTerminal as _;
    if !std::io::stdin().is_terminal() {
        return Prompt(None);
    }
    let scope = cmux_scope::Scope::new("resume-here permission prompt");
    let id = id.to_owned();
    let (asking, asked) = watch::channel(false);
    let (tx, lines) = mpsc::channel(8);
    scope.spawn_until_cancelled("resume-here stdin", stdin_lines(asked, tx));
    scope.spawn_until_cancelled("resume-here prompt", async move {
        // Its own connection: the attach stream above owns the first one's notifications.
        let unasked =
            || println!("\x1b[2m-- a permission this turn asks for is answered in the chat\x1b[0m");
        let Ok(client) = crate::daemon::connect(true).await else { return unasked() };
        let (out, mut printed) = mpsc::unbounded_channel::<String>();
        // Prints until `follow` ends (it holds the only sender).
        let print = async move {
            use std::io::Write as _;
            while let Some(text) = printed.recv().await {
                print!("\n{text}");
                let _ = std::io::stdout().flush();
            }
        };
        // A chat this daemon only mirrors (a peer's: its hold attach is local only) or a lost
        // connection: say where it is answered instead.
        let ((), followed) = tokio::join!(print, follow(client, &id, lines, asking, out));
        if followed.is_err() {
            unasked();
        }
    });
    Prompt(Some(scope))
}

/// Stdin's lines into `tx`, read only while `asking` is true, so a line typed while no question
/// is up stays for the harness. Each read is one bounded blocking call (a 250 ms poll, then a read
/// of the line it found), awaited by this task: it ends with the prompt's scope.
#[cfg(unix)]
async fn stdin_lines(mut asking: watch::Receiver<bool>, tx: mpsc::Sender<String>) {
    loop {
        if !*asking.borrow_and_update() {
            if asking.changed().await.is_err() {
                return;
            }
            continue;
        }
        match tokio::task::spawn_blocking(read_line_within_250ms).await {
            Ok(Read::Line(line)) => {
                if tx.send(line).await.is_err() {
                    return;
                }
            }
            Ok(Read::Nothing) => {}
            // Stdin closed or failed: nothing more to read.
            Ok(Read::Ended) | Err(_) => return,
        }
    }
}

#[cfg(unix)]
enum Read {
    Line(String),
    Nothing,
    Ended,
}

/// One line from stdin if one is ready within 250 ms. In cooked mode one read is one line.
#[cfg(unix)]
fn read_line_within_250ms() -> Read {
    let mut fd = libc::pollfd { fd: 0, events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd for the duration of the call.
    if unsafe { libc::poll(&mut fd, 1, 250) } <= 0 {
        return Read::Nothing;
    }
    let mut buf = [0u8; 4096];
    // SAFETY: reads into `buf`, at most its length.
    let n = unsafe { libc::read(0, buf.as_mut_ptr().cast(), buf.len()) };
    match usize::try_from(n).ok().filter(|n| *n > 0).and_then(|n| buf.get(..n)) {
        Some(read) => Read::Line(String::from_utf8_lossy(read).into_owned()),
        None => Read::Ended,
    }
}

#[cfg(not(unix))]
async fn stdin_lines(_asking: watch::Receiver<bool>, _tx: mpsc::Sender<String>) {}

#[cfg(test)]
#[path = "resume_here_ask_tests.rs"]
mod tests;
