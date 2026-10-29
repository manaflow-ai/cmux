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
//! A stopped turn, a failed one, and the step a Send now interrupts keep the old way: the
//! unread line runs as one more turn of the same prompt (`steer_now.rs`).

use super::*;

/// The carried turns of a Claude Code process.
#[derive(Debug, Default)]
pub(super) struct Carry {
    /// Carries so far: each names its own (`_meta.claude.carried.seq`).
    seq: u64,
    /// Carried turns whose `_meta.carried` prompt has not come yet.
    owed: usize,
    /// Their answers, when their result came first, oldest first.
    answers: std::collections::VecDeque<Result<Value, RpcError>>,
    /// Unread steers (ACP request ids) at a carry, by that carry's `seq`.
    pub(super) steers: HashMap<String, u64>,
}

impl Carry {
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
        let mut prompt_ids = Vec::new();
        for (id, prompt) in parts {
            carry.steers.insert(id, seq);
            prompt_ids.extend(prompt);
        }
        json!({"seq": seq, "promptIds": prompt_ids})
    }

    /// The carry a steer read now was left by, if any (its `steered` answer names it).
    pub(super) async fn carried_steer(&self, id: &str) -> Option<u64> {
        self.carry.lock().await.steers.remove(id)
    }

    /// The hub's prompt for a carried turn (`_meta.carried`): its answer when the turn's result
    /// came first, else it waits for that result. With no carried turn it ends at once.
    pub(super) async fn adopt_carried(&self, id: &Id) -> Outbound {
        let mut carry = self.carry.lock().await;
        if let Some(answer) = carry.answers.pop_front() {
            carry.owed = carry.owed.saturating_sub(1);
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
        Outbound::Lines(Vec::new())
    }

    /// A new prompt of the hub's, or answers that are lost: no carried turn is owed any more.
    pub(super) async fn clear_carry(&self) {
        let mut carry = self.carry.lock().await;
        carry.owed = 0;
        carry.answers.clear();
        carry.steers.clear();
    }
}
