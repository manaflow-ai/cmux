//! Auto-resume of agent CLIs in cmux terminals (Claude Code, Codex): the
//! terminal side of auto_resume.rs. Every [`POLL`] the watcher lists the
//! terminals; an agent terminal whose agent reports `error` (cmux program
//! status), or that sits idle at its prompt with an error as its last
//! output line, stopped on an error. It is classified as auto_resume.rs
//! does: a transient error is told to continue (typed at its prompt) after
//! a backoff, a network error waits until the model endpoint answers. Each
//! event reaches the Chief's chat as `[term_…] stopped: <reason>`.
//!
//! Nothing is typed into a terminal that works, waits on a question
//! (`blocked`), or has text in its prompt line. A user can turn it off with
//! `OPTCHAT_TERMINAL_RESUME=off`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::auto_resume::{Decision, ResumePolicy, StopKind, chief_note, classify, decide};

/// How often the watcher looks at the terminals.
pub const POLL: Duration = Duration::from_secs(30);

/// What the watcher reads of one terminal.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TermInfo {
    pub id: String,
    pub title: String,
    /// The agent the terminal reports (`claude-code`, `codex`), if any.
    pub agent: Option<String>,
    /// That agent's state (`working`, `idle`, `done`, `error`, `blocked`).
    pub state: Option<String>,
    pub running: bool,
}

/// The cmux terminals, as the watcher needs them.
pub trait Terminals: Send + Sync {
    fn list(&self) -> Result<Vec<TermInfo>, String>;
    fn screen(&self, id: &str) -> Result<String, String>;
    /// Types `text` at the terminal's prompt and presses Enter.
    fn submit(&self, id: &str, text: &str) -> Result<(), String>;
}

/// What the watcher does next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// A line for the Chief's chat; `quiet` when no Chief action is needed.
    Note { text: String, quiet: bool },
    /// Type a continue into terminal `id`.
    Continue { id: String, text: String },
}

#[derive(Clone, Debug)]
struct Pending {
    reason: String,
    attempt: u32,
    /// None: wait for the network; Some: when the retry is due.
    due: Option<Instant>,
}

/// The watcher's memory across ticks.
pub struct Watcher {
    policy: ResumePolicy,
    /// Continues in a row per terminal (0 again once it works without error).
    attempts: HashMap<String, u32>,
    /// The stop each terminal is handled for (its error line), so one stop
    /// is never handled twice.
    handled: HashMap<String, String>,
    pending: HashMap<String, Pending>,
}

/// The agent apps the watcher handles.
fn is_agent(agent: Option<&str>) -> bool {
    matches!(agent, Some("claude-code" | "codex"))
}

/// The last lines an agent wrote, without its prompt box and footer
/// (prompt `❯`/`›`, rules, `⏵⏵` mode line, `✻ … done` timer, cost line).
pub fn agent_tail(screen: &str) -> Vec<&str> {
    let mut out: Vec<&str> = Vec::new();
    for line in screen.lines().rev() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        let chrome = t.starts_with('❯')
            || t.starts_with('›')
            || t.starts_with("⏵⏵")
            || t.chars()
                .all(|c| matches!(c, '─' | '━' | '╭' | '╮' | '╰' | '╯' | '│' | ' '))
            || t.starts_with('✻')
            || t.starts_with("? for shortcuts")
            || t.contains("% ctx")
            || t.contains("Context") && t.contains("left")
            || t.starts_with("※ recap")
            || t.starts_with("⎿  Tip:");
        if chrome {
            if out.is_empty() {
                continue;
            }
            break;
        }
        out.push(t);
        if out.len() >= 4 {
            break;
        }
    }
    out.reverse();
    out
}

/// The text in the agent's prompt line (`❯ …`), empty when none.
pub fn prompt_text(screen: &str) -> Option<String> {
    screen.lines().rev().find_map(|l| {
        let t = l.trim_start();
        t.strip_prefix('❯')
            .or_else(|| t.strip_prefix('›'))
            .map(|rest| rest.trim().to_owned())
    })
}

/// The agent's error line on `screen`, as one report: its last output
/// lines joined (a wrapped `API Error: ... may be` / `incomplete.`).
fn screen_report(screen: &str) -> String {
    let tail = agent_tail(screen);
    // The error starts at its `API Error` line; join it with what wraps.
    let start = tail
        .iter()
        .rposition(|l| {
            let l = l.trim_start_matches('⏺').trim_start().to_ascii_lowercase();
            l.starts_with("api error") || l.starts_with("error:") || l.starts_with("■")
        })
        .unwrap_or(tail.len().saturating_sub(1));
    tail[start.min(tail.len())..]
        .iter()
        .map(|l| l.trim_start_matches('⏺').trim_start_matches('■').trim())
        .collect::<Vec<_>>()
        .join(" ")
}

impl Watcher {
    pub fn new(policy: ResumePolicy) -> Watcher {
        Watcher {
            policy,
            attempts: HashMap::new(),
            handled: HashMap::new(),
            pending: HashMap::new(),
        }
    }

    /// One look at the terminals: `screen` reads one terminal's screen,
    /// `online` says whether the model endpoint answers (asked only when a
    /// network stop waits). The actions, in order.
    pub fn tick(
        &mut self,
        terms: &[TermInfo],
        screen: &mut dyn FnMut(&str) -> Option<String>,
        online: &mut dyn FnMut() -> bool,
        now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();
        let mut online_now: Option<bool> = None;
        for t in terms {
            if !t.running || !is_agent(t.agent.as_deref()) {
                self.forget(&t.id);
                continue;
            }
            let state = t.state.as_deref().unwrap_or("");
            if state == "working" {
                // It works again (a person or a continue). Its count of
                // continues stays until it ends with a real report.
                self.handled.remove(&t.id);
                self.pending.remove(&t.id);
                continue;
            }
            // Only a stopped agent at its prompt: never one that asks.
            if !matches!(state, "error" | "idle" | "done" | "") {
                continue;
            }
            let Some(text) = screen(&t.id) else { continue };
            if prompt_text(&text).is_some_and(|p| !p.is_empty()) {
                continue;
            }
            let report = screen_report(&text);
            let kind = classify(&report, false);
            if matches!(kind, StopKind::Done | StopKind::UserStopped) {
                if state != "error" {
                    self.pending.remove(&t.id);
                    self.handled.remove(&t.id);
                    self.attempts.remove(&t.id);
                }
                continue;
            }
            // A pending continue comes due.
            if let Some(p) = self.pending.get(&t.id).cloned() {
                let due = match p.due {
                    Some(at) => now >= at,
                    None => *online_now.get_or_insert_with(&mut *online),
                };
                if due {
                    self.pending.remove(&t.id);
                    actions.push(Action::Continue {
                        id: t.id.clone(),
                        text: crate::auto_resume::continue_prompt(
                            &p.reason,
                            p.attempt,
                            p.due.is_none(),
                        ),
                    });
                    actions.push(Action::Note {
                        text: format!("[{}] auto-resume {}: told it to continue", t.id, p.attempt),
                        quiet: true,
                    });
                }
                continue;
            }
            if self.handled.get(&t.id) == Some(&report) {
                continue;
            }
            self.handled.insert(t.id.clone(), report.clone());
            let attempts = self.attempts.get(&t.id).copied().unwrap_or(0);
            let decision = decide(&kind, attempts, &self.policy, false);
            let label = if t.title.is_empty() {
                t.id.clone()
            } else {
                format!("{} ({})", t.id, t.title)
            };
            if let Some(note) = chief_note(&decision) {
                let quiet = !matches!(decision, Decision::Report { .. });
                actions.push(Action::Note {
                    text: format!("[{label}] {note}"),
                    quiet,
                });
            }
            match decision {
                Decision::Report { .. } => {
                    self.attempts.remove(&t.id);
                }
                Decision::Retry {
                    reason,
                    attempt,
                    delay,
                } => {
                    self.attempts.insert(t.id.clone(), attempt);
                    self.pending.insert(
                        t.id.clone(),
                        Pending {
                            reason,
                            attempt,
                            due: Some(now + delay),
                        },
                    );
                }
                Decision::WaitOnline { reason, attempt } => {
                    self.attempts.insert(t.id.clone(), attempt);
                    self.pending.insert(
                        t.id.clone(),
                        Pending {
                            reason,
                            attempt,
                            due: None,
                        },
                    );
                }
            }
        }
        // Terminals that are gone.
        let ids: std::collections::HashSet<&str> = terms.iter().map(|t| t.id.as_str()).collect();
        self.pending.retain(|id, _| ids.contains(id.as_str()));
        self.handled.retain(|id, _| ids.contains(id.as_str()));
        self.attempts.retain(|id, _| ids.contains(id.as_str()));
        actions
    }

    fn forget(&mut self, id: &str) {
        self.attempts.remove(id);
        self.handled.remove(id);
        self.pending.remove(id);
    }
}

/// Runs the watcher on its own thread: each [`POLL`] it ticks, types the
/// continues and sends each note to the brain
/// ([`crate::brain::Input::TerminalStopped`]). It ends when the brain does.
pub fn spawn(
    policy: ResumePolicy,
    terminals: std::sync::Arc<dyn Terminals>,
    reach: std::sync::Arc<dyn crate::auto_resume::Reachability>,
    tx: std::sync::mpsc::Sender<crate::brain::Input>,
    log: crate::brain::Log,
) {
    std::thread::spawn(move || {
        let mut watcher = Watcher::new(policy);
        let mut failing = false;
        loop {
            match terminals.list() {
                Ok(terms) => {
                    failing = false;
                    let mut screen = |id: &str| terminals.screen(id).ok();
                    let mut online = || reach.online();
                    for action in watcher.tick(&terms, &mut screen, &mut online, Instant::now()) {
                        match action {
                            Action::Continue { id, text } => {
                                if let Err(e) = terminals.submit(&id, &text) {
                                    log(&format!(
                                        "ERROR terminal {id}: the auto-resume could not be typed: {e}"
                                    ));
                                }
                            }
                            Action::Note { text, quiet } => {
                                // WARN: `cmux errors` harvests host.log lines by level word.
                                log(&format!("WARN terminal auto-resume: {text}"));
                                if tx
                                    .send(crate::brain::Input::TerminalStopped { text, quiet })
                                    .is_err()
                                {
                                    return;
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    if !failing {
                        log(&format!(
                            "terminal watch: listing the terminals failed: {e}"
                        ));
                    }
                    failing = true;
                }
            }
            // The poll interval of a watcher with no event to wait on.
            std::thread::sleep(POLL);
        }
    });
}

/// [`Terminals`] through the `cmux` CLI (`terminal list|screen read|write|keys`).
pub struct CliTerminals {
    pub cli: PathBuf,
}

impl CliTerminals {
    /// The bundled CLI (`CMUX_BUNDLED_CLI_PATH`), else `cmux` on PATH.
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> CliTerminals {
        CliTerminals {
            cli: get("CMUX_BUNDLED_CLI_PATH")
                .filter(|p| !p.is_empty())
                .map_or_else(|| PathBuf::from("cmux"), PathBuf::from),
        }
    }

    fn run(&self, args: &[&str]) -> Result<String, String> {
        let out = Command::new(&self.cli)
            .args(args)
            .output()
            .map_err(|e| format!("{}: {e}", self.cli.display()))?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_owned());
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

/// The terminals of `cmux terminal list --json`.
pub fn parse_list(json: &str) -> Result<Vec<TermInfo>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let items = v
        .as_array()
        .or_else(|| v.get("items").and_then(Value::as_array))
        .ok_or("terminal list: no array")?;
    Ok(items
        .iter()
        .map(|t| {
            let status = t
                .pointer("/extra/program_status")
                .and_then(Value::as_array)
                .and_then(|a| {
                    a.iter()
                        .find(|p| is_agent(p.get("app").and_then(Value::as_str)))
                });
            TermInfo {
                id: t.get("id").and_then(Value::as_str).unwrap_or("").to_owned(),
                title: t
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .chars()
                    .take(60)
                    .collect(),
                agent: status
                    .and_then(|p| p.get("app"))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                state: status
                    .and_then(|p| p.get("state"))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                running: t.get("running").and_then(Value::as_bool).unwrap_or(false),
            }
        })
        .collect())
}

impl Terminals for CliTerminals {
    fn list(&self) -> Result<Vec<TermInfo>, String> {
        parse_list(&self.run(&["terminal", "list", "--json"])?)
    }

    fn screen(&self, id: &str) -> Result<String, String> {
        let v: Value =
            serde_json::from_str(&self.run(&["terminal", id, "screen", "read", "--json"])?)
                .map_err(|e| e.to_string())?;
        Ok(v.get("text")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned())
    }

    fn submit(&self, id: &str, text: &str) -> Result<(), String> {
        self.run(&["terminal", id, "write", "--text", text])?;
        self.run(&["terminal", id, "keys", "enter"])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONNECTION_LOST: &str = "⏺ Writing the Swift settings test.\n  Ran 2 shell commands\n⏺ API Error: Connection lost mid-response. The response above may be\n  incomplete.\n✻ Sautéed for 20m 50s · done 9:54 PM\n────────\n❯ \n────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n";
    const OVERLOADED: &str = "⏺ API Error: 529 {\"type\":\"overloaded_error\"}\n✻ Brewed for 3s · done 9:00 PM\n────\n❯ \n────\n  ⏵⏵ bypass permissions on\n";
    const REPORT: &str = "⏺ Pushed abc123. Reply `keep` or `drop`.\n✻ Brewed for 3s · done 9:00 PM\n────\n❯ \n────\n";

    fn term(id: &str, state: &str) -> TermInfo {
        TermInfo {
            id: id.into(),
            title: "Claude Code".into(),
            agent: Some("claude-code".into()),
            state: Some(state.into()),
            running: true,
        }
    }

    #[test]
    fn the_tail_skips_the_prompt_box() {
        assert_eq!(
            screen_report(CONNECTION_LOST),
            "API Error: Connection lost mid-response. The response above may be incomplete."
        );
    }

    #[test]
    fn a_network_stop_waits_until_online_then_continues_once() {
        let mut w = Watcher::new(ResumePolicy::default());
        let t0 = Instant::now();
        let terms = [term("term_a", "error")];
        let mut screen = |_: &str| Some(CONNECTION_LOST.to_owned());
        let mut offline = || false;
        let a = w.tick(&terms, &mut screen, &mut offline, t0);
        assert!(
            matches!(&a[..], [Action::Note { quiet: true, .. }]),
            "{a:?}"
        );
        // Still offline: nothing.
        assert!(
            w.tick(&terms, &mut screen, &mut offline, t0 + POLL)
                .is_empty()
        );
        let mut online = || true;
        let a = w.tick(&terms, &mut screen, &mut online, t0 + POLL * 2);
        assert!(
            matches!(&a[0], Action::Continue { id, text } if id == "term_a" && text.contains("The network is back")),
            "{a:?}"
        );
        // Same screen again (the continue not shown yet): no second continue.
        assert!(
            w.tick(&terms, &mut screen, &mut online, t0 + POLL * 3)
                .is_empty()
        );
    }

    #[test]
    fn a_transient_stop_continues_after_its_backoff() {
        let mut w = Watcher::new(ResumePolicy::default());
        let t0 = Instant::now();
        let terms = [term("term_b", "idle")];
        let mut screen = |_: &str| Some(OVERLOADED.to_owned());
        let mut online = || true;
        assert_eq!(w.tick(&terms, &mut screen, &mut online, t0).len(), 1);
        assert!(
            w.tick(
                &terms,
                &mut screen,
                &mut online,
                t0 + Duration::from_secs(10)
            )
            .is_empty()
        );
        let a = w.tick(
            &terms,
            &mut screen,
            &mut online,
            t0 + Duration::from_secs(31),
        );
        assert!(matches!(&a[0], Action::Continue { .. }), "{a:?}");
    }

    #[test]
    fn working_blocked_typed_or_reported_terminals_are_left_alone() {
        let mut w = Watcher::new(ResumePolicy::default());
        let t0 = Instant::now();
        let mut online = || true;
        let mut lost = |_: &str| Some(CONNECTION_LOST.to_owned());
        for state in ["working", "blocked"] {
            assert!(
                w.tick(&[term("t", state)], &mut lost, &mut online, t0)
                    .is_empty()
            );
        }
        let mut typed = |_: &str| Some(CONNECTION_LOST.replace("❯ ", "❯ half a message"));
        assert!(
            w.tick(&[term("t", "error")], &mut typed, &mut online, t0)
                .is_empty()
        );
        let mut report = |_: &str| Some(REPORT.to_owned());
        assert!(
            w.tick(&[term("t", "done")], &mut report, &mut online, t0)
                .is_empty()
        );
        let mut plain = TermInfo {
            agent: None,
            ..term("t", "error")
        };
        plain.title = "zsh".into();
        assert!(w.tick(&[plain], &mut lost, &mut online, t0).is_empty());
    }

    #[test]
    fn it_gives_up_after_the_retry_limit() {
        let policy = ResumePolicy {
            max_attempts: 1,
            base_backoff: Duration::from_secs(1),
            ..ResumePolicy::default()
        };
        let mut w = Watcher::new(policy);
        let t0 = Instant::now();
        let terms = [term("t", "idle")];
        let mut online = || true;
        let mut s1 = |_: &str| Some(OVERLOADED.to_owned());
        w.tick(&terms, &mut s1, &mut online, t0);
        let a = w.tick(&terms, &mut s1, &mut online, t0 + Duration::from_secs(2));
        assert!(matches!(&a[0], Action::Continue { .. }));
        // It failed again with a new error: reported, not retried.
        let mut s2 = |_: &str| Some(OVERLOADED.replace("529", "529 again"));
        let a = w.tick(&terms, &mut s2, &mut online, t0 + Duration::from_secs(3));
        assert!(
            matches!(&a[..], [Action::Note { quiet: false, text }] if text.contains("gave up")),
            "{a:?}"
        );
    }

    #[test]
    fn the_list_json_is_read() {
        let json = r#"[{"id":"term_x","title":"Claude Code","running":true,"extra":{"program_status":[{"app":"claude-code","state":"error"}]}},{"id":"term_y","running":true,"extra":{}}]"#;
        let l = parse_list(json).unwrap();
        assert_eq!(l[0].state.as_deref(), Some("error"));
        assert_eq!(l[0].agent.as_deref(), Some("claude-code"));
        assert_eq!(l[1].agent, None);
    }
}
