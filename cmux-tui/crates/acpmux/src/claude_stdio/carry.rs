//! A turn ends when Claude Code ends it (Leo, 2026-10-29: "why the fuck are you still depicted as
//! thinking for 11 hours? This feels like we're not reading the data correctly. Because you're,
//! like, you clearly just ended some fucking turns, and it still fucking shows this.").
//!
//! Claude Code reads a steered line at its next tool boundary. A line it has not read when its
//! turn ends (`result`) it runs next, as a turn of its own. That turn used to stay part of the
//! prompt's: the prompt was answered only at a result with no line left unread, so a chat that
//! kept getting messages ran one turn for hours while Claude Code ended many.
//!
//! Now a clean result (not stopped, not failed) with lines unread answers the prompt there,
//! marked `_meta.claude.carried: {seq, promptIds}`: the turn ended, and Claude Code runs on with
//! the steers named (their hub promptIds, oldest first). The hub ends its turn and starts the next
//! one (`hub/carried_turn.rs`), whose `session/prompt` is `_meta.carried: true`: nothing is
//! written, and it is answered at the result of the turn Claude Code runs now, or at once when
//! that result came first. A steer read after the carry is answered `steered` with
//! `_meta.claude.carried: seq`, so the hub names the turn it went into.
//!
//! Until that prompt comes, what Claude Code writes next is not read (`holding`): the hub logs the
//! turn's end and the next one's start before it sends the prompt, so the next turn's output is
//! logged inside the next turn (`agent.rs` reader, `agent_host/host.rs` `on_stdout`). The hold is
//! bounded ([`HOLD_MAX`]).
//!
//! A stopped turn, a failed one, and the step a Send now interrupts keep the old way: the
//! unread line runs as one more turn of the same prompt (`steer_now.rs`).

use super::*;

/// The longest the output after a carry waits for the next turn's prompt: past it, it is read.
pub const HOLD_MAX: std::time::Duration = std::time::Duration::from_secs(10);

/// The carried turns of a Claude Code process.
#[derive(Debug, Default)]
pub(super) struct Carry {
    /// The last carry's number (`_meta.claude.carried.seq`). It starts at the process's start
    /// time in microseconds, so a respawned process never reuses an earlier one's.
    seq: u64,
    /// The carry whose turn Claude Code runs now, until a result carries nothing: a steer it
    /// reads meanwhile is in that turn.
    current: Option<u64>,
    /// Carried turns whose `_meta.carried` prompt has not come yet.
    owed: usize,
    /// Their answers, when their result came first, oldest first.
    answers: std::collections::VecDeque<Result<Value, RpcError>>,
    /// Unread steers (ACP request ids) at a carry, by that carry's `seq`.
    pub(super) steers: HashMap<String, u64>,
}

impl Carry {
    /// A new process's: its carries number from now.
    pub(super) fn new() -> Self {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
        Self { seq: now.map_or(0, |d| d.as_micros() as u64), ..Self::default() }
    }

    /// A result that carries nothing: Claude Code runs no carried turn now.
    pub(super) fn ended(&mut self) {
        self.current = None;
    }

    /// A result no prompt waits for: kept for the carried turn whose prompt is still to come.
    /// Under the carry lock, taken before `pending` is read, so a prompt that comes meanwhile
    /// either waits in `pending` or finds this answer.
    pub(super) fn keep(&mut self, answer: Result<Value, RpcError>) {
        if self.owed > self.answers.len() {
            self.answers.push_back(answer);
        }
    }

    /// A carry's turn is owed its prompt.
    pub(super) fn owe(&mut self) {
        self.owed += 1;
    }

    /// Answers were lost (`fail_pending`): each carried turn whose prompt has not come yet ends
    /// with `message` when it comes, never as a success.
    pub(super) fn fail_owed(&mut self, message: &str) {
        while self.answers.len() < self.owed {
            self.answers.push_back(Err(RpcError::internal(message)));
        }
        self.steers.clear();
        self.current = None;
    }
}

impl Translator {
    /// A result that ends a turn with steered lines unread: the steers it leaves (and those held
    /// for a line written again, `steer_batch.rs`), named for the next turn. Returns the answer's
    /// `_meta.claude.carried`.
    pub(super) async fn carry_unread(&self) -> Value {
        let batches = self.batches.lock().await;
        let steers = self.steers.lock().await;
        let lines = self.steer_lines.lock().await;
        let mut parts: Vec<(String, Option<String>)> = Vec::new();
        let mut seen: Vec<&str> = Vec::new();
        for (uuid, id) in steers.iter() {
            match batches.lines.get(uuid) {
                // A line of several sessions' messages: each in its order, once.
                Some(batch) => {
                    if !seen.contains(&uuid.as_str()) {
                        seen.push(uuid);
                        parts.extend(batch.iter().map(|p| (p.id.clone(), p.prompt_id.clone())));
                    }
                }
                None => {
                    let prompt = lines.iter().find(|(_, u)| *u == uuid).map(|(p, _)| p.clone());
                    parts.push((id.clone(), prompt));
                }
            }
        }
        if let Some((_, held)) = batches.rewrite.as_ref() {
            parts.extend(held.iter().map(|p| (p.id.clone(), p.prompt_id.clone())));
        }
        drop(lines);
        drop(steers);
        drop(batches);
        let mut carry = self.carry.lock().await;
        carry.seq += 1;
        let seq = carry.seq;
        carry.current = Some(seq);
        let mut prompt_ids = Vec::new();
        for (id, prompt) in parts {
            carry.steers.insert(id, seq);
            prompt_ids.extend(prompt);
        }
        json!({"seq": seq, "promptIds": prompt_ids})
    }

    /// The carry whose turn a steer read now is in, if any (its `steered` answer names it): the
    /// one that left it unread, or the one Claude Code runs now (it came after that carry).
    pub(super) async fn carried_steer(&self, id: &str) -> Option<u64> {
        let mut carry = self.carry.lock().await;
        carry.steers.remove(id).or(carry.current)
    }

    /// The hub's prompt for a carried turn (`_meta.carried`): its answer when the turn's result
    /// came first, else it waits for that result. With no carried turn it ends at once.
    pub(super) async fn adopt_carried(&self, id: &Id) -> Outbound {
        let mut carry = self.carry.lock().await;
        if let Some(answer) = carry.answers.pop_front() {
            carry.owed = carry.owed.saturating_sub(1);
            self.carry_owed.send_replace((carry.owed, carry.seq));
            return Outbound::Reply(match answer {
                Ok(v) => Message::ok(id.clone(), v),
                Err(e) => Message::err(id.clone(), e),
            });
        }
        if carry.owed == 0 {
            return Outbound::Reply(Message::ok(id.clone(), json!({"stopReason": "end_turn"})));
        }
        carry.owed -= 1;
        // Taken while the carry lock is held: the result that answers it takes that lock first.
        self.pending.lock().await.insert(id.to_string(), Pending::Prompt);
        self.carry_owed.send_replace((carry.owed, carry.seq));
        Outbound::Lines(Vec::new())
    }

    /// The output after a carry is held while a carried turn's prompt has not come yet: the
    /// newest carry's number, so a reader gives each carry a hold of its own, also one made
    /// while an earlier carry's prompt is still to come.
    pub fn holding(&self) -> Option<u64> {
        let (owed, seq) = *self.carry_owed.borrow();
        (owed > 0).then_some(seq)
    }

    /// Waits, at most `max`, until no carried turn waits for its prompt.
    pub async fn wait_unheld(&self, max: std::time::Duration) {
        let mut owed = self.carry_owed.subscribe();
        let _ = tokio::time::timeout(max, owed.wait_for(|(n, _)| *n == 0)).await;
    }

    /// A result carried (`carried`) or not: the carry state after it, under its lock.
    pub(super) fn carry_settled(&self, carry: &mut Carry, carried: bool) {
        if carried {
            carry.owe();
        } else {
            carry.ended();
        }
        self.carry_owed.send_replace((carry.owed, carry.seq));
    }

    /// A new prompt of the hub's: no carried turn is owed any more.
    pub(super) async fn clear_carry(&self) {
        let mut carry = self.carry.lock().await;
        carry.owed = 0;
        carry.current = None;
        carry.answers.clear();
        carry.steers.clear();
        self.carry_owed.send_replace((0, carry.seq));
    }
}
