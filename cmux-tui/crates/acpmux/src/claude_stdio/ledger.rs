//! The user lines acpmux wrote to Claude Code's stdin, oldest first, until
//! the prompt each belongs to is answered.
//!
//! Claude Code reads its stdin in order. A line it reads while idle starts a
//! turn that one `result` ends; a line it reads during a turn (a steer, or a
//! prompt queued behind a stopped turn) joins that turn. After a Stop Claude
//! Code answers late, acpmux ends the turn itself (`hub/cancel.rs`) and sends
//! the next prompt, so several prompts can be waiting on Claude Code at once,
//! and "the newest prompt" is not what a result ends: the oldest line still
//! waiting is. Claude Code 2.1.299 also names the lines a result ends
//! (`user_message_uuids`), which settles it without counting.

use std::collections::VecDeque;

/// One user line on Claude Code's stdin.
struct Line {
    /// The line's `uuid`, which Claude Code's echo and result carry.
    uuid: String,
    /// The ACP prompt the line belongs to: its own, or the one a steer joins.
    prompt: String,
    /// A steer's own ACP request, answered once Claude Code reads the line.
    steer: Option<String>,
    /// Claude Code echoed it (`--replay-user-messages`).
    read: bool,
    /// Its turn's result came, or it joined a turn already running.
    done: bool,
    /// A Stop came while it was waiting: its turn ends cancelled.
    cancelled: bool,
    /// The line that Stop's interrupt reached (the one Claude Code was on).
    interrupted: bool,
}

/// What a result or an echo answers.
#[derive(Debug, PartialEq)]
pub(super) enum Answer {
    /// A steer Claude Code read.
    Steered(String),
    /// A steer whose turn ended unread (a Claude Code that echoes nothing).
    SteerUnread(String),
    /// A prompt whose lines are all done. `cancelled`: a Stop came for it.
    /// `own`: this result ended its turn, so the result's outcome is its
    /// answer; a prompt whose result never came is answered without one.
    Prompt { id: String, cancelled: bool, own: bool },
}

/// A result's answers, and whether the turn it ended was stopped.
pub(super) struct Ended {
    pub answers: Vec<Answer>,
    pub cancelled: bool,
}

#[derive(Default)]
pub(super) struct Ledger {
    lines: VecDeque<Line>,
}

impl Ledger {
    /// A prompt is waiting on Claude Code (a steer has a turn to join).
    pub fn is_open(&self) -> bool {
        !self.lines.is_empty()
    }

    pub fn push_prompt(&mut self, uuid: String, id: String) {
        self.lines.push_back(Line {
            uuid,
            prompt: id,
            steer: None,
            read: false,
            done: false,
            cancelled: false,
            interrupted: false,
        });
    }

    /// A steer joins the newest prompt, and a Stop already sent for it.
    pub fn push_steer(&mut self, uuid: String, id: String) {
        let Some(prompt) = self.lines.back().map(|l| l.prompt.clone()) else { return };
        let cancelled = self.group_cancelled(&prompt);
        self.lines.push_back(Line {
            uuid,
            prompt,
            steer: Some(id),
            read: false,
            done: false,
            cancelled,
            interrupted: false,
        });
    }

    /// Stop stops every line still waiting; its interrupt reaches the one
    /// Claude Code is on, the oldest.
    pub fn stop(&mut self) {
        for line in &mut self.lines {
            line.cancelled = true;
        }
        if let Some(line) = self.lines.iter_mut().find(|l| !l.done) {
            line.interrupted = true;
        }
    }

    /// The line Claude Code is on was stopped: a result for it is never
    /// startup noise.
    pub fn head_cancelled(&self) -> bool {
        self.lines.iter().find(|l| !l.done).is_some_and(|l| l.cancelled)
    }

    /// Claude Code echoed line `uuid`. Returns a steer's answer, and true
    /// when the line starts a turn that a Stop already covers (Claude Code
    /// keeps queued lines past an interrupt), so that turn needs its own.
    pub fn read(&mut self, uuid: &str) -> (Option<Answer>, bool) {
        let Some(at) = self.lines.iter().position(|l| !uuid.is_empty() && l.uuid == uuid) else {
            return (None, false);
        };
        if self.lines[at].read {
            return (None, false);
        }
        let joins = self.lines.iter().take(at).any(|l| !l.done);
        let cancelled = self.group_cancelled(&self.lines[at].prompt.clone());
        let line = &mut self.lines[at];
        line.read = true;
        // Read during an earlier line's turn: it joins that turn, whose
        // result ends it.
        line.done |= joins;
        let interrupt = !joins && cancelled && !line.interrupted;
        line.interrupted |= interrupt;
        (line.steer.clone().map(Answer::Steered), interrupt)
    }

    /// A result: it ends the lines it names, else the oldest line waiting.
    /// None when it ends no line of ours (a resumed process's first result).
    pub fn result(&mut self, named: Option<&[String]>) -> Option<Ended> {
        let mut answers = Vec::new();
        let ended: Vec<String> = match named {
            Some(named) => {
                let last = self.lines.iter().rposition(|l| named.contains(&l.uuid))?;
                // Claude Code reads in order: every line before the last one
                // named was read and its turn is over, result or not.
                for line in self.lines.iter_mut().take(last + 1).filter(|l| !l.done) {
                    line.done = true;
                    if !line.read {
                        line.read = true;
                        answers.extend(line.steer.clone().map(Answer::Steered));
                    }
                }
                let own = self.lines.iter().filter(|l| named.contains(&l.uuid));
                own.map(|l| l.prompt.clone()).collect()
            }
            None => {
                let line = self.lines.iter_mut().find(|l| !l.done)?;
                line.done = true;
                // A steer whose own turn this was (its prompt was echoed).
                if let Some(steer) = line.steer.clone().filter(|_| !line.read) {
                    line.read = true;
                    answers.push(Answer::Steered(steer));
                }
                let prompt = line.prompt.clone();
                // A steer still unread when its prompt's turn ended: when
                // Claude Code echoes lines it runs it as one more turn of the
                // prompt; without echoes it never will.
                let echoes =
                    self.lines.iter().any(|l| l.prompt == prompt && l.steer.is_none() && l.read);
                if !echoes {
                    for steer in self.lines.iter_mut().filter(|l| l.prompt == prompt && !l.done) {
                        steer.done = true;
                        answers.extend(steer.steer.clone().map(Answer::SteerUnread));
                    }
                }
                vec![prompt]
            }
        };
        let cancelled = ended.iter().any(|p| self.group_cancelled(p));
        let mut prompts: Vec<String> = Vec::new();
        for line in &self.lines {
            if !prompts.contains(&line.prompt) {
                prompts.push(line.prompt.clone());
            }
        }
        for prompt in prompts {
            if self.lines.iter().any(|l| l.prompt == prompt && !l.done) {
                continue;
            }
            let cancelled = self.group_cancelled(&prompt);
            let own = ended.contains(&prompt);
            self.lines.retain(|l| l.prompt != prompt);
            answers.push(Answer::Prompt { id: prompt, cancelled, own });
        }
        Some(Ended { answers, cancelled })
    }

    /// The steers no answer reached yet, and the ledger emptied: Claude
    /// Code's answers can no longer be carried.
    pub fn drain_steers(&mut self) -> Vec<String> {
        self.lines.drain(..).filter(|l| !l.read).filter_map(|l| l.steer).collect()
    }

    fn group_cancelled(&self, prompt: &str) -> bool {
        self.lines.iter().any(|l| l.prompt == prompt && l.cancelled)
    }
}
