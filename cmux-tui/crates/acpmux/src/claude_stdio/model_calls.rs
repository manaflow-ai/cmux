//! When each of the chat's own model calls went out and came back, for the turn's Timeline (Leo,
//! 2026-11-27, on a turn whose Timeline read "Thinking 3ms": "was your thinkin really 3ms only? from
//! anthropic and back?").
//!
//! A client that times thinking from its first thought chunk to its last measures almost nothing:
//! Claude Code's thinking arrives in one burst at the end of the call's wait. Over 163 main-loop
//! calls in one host's journals (2026-11-27), the first to the last thought chunk was 20 ms at the
//! median, while the request to the first thought chunk was 11.5 s. So acpmux stamps the call
//! itself, here where its stream is read:
//! - `requestAt`: the request went out, the latest of the prompt written to Claude Code's stdin
//!   (`outbound.rs`) and the chat's own `user` lines (the prompt's echo, its tool results) before
//!   the call's first byte. A call with neither since the last one (a retry, a continuation) went
//!   out when the last one ended.
//! - `firstTokenAt`: its `message_start`, the response's first byte.
//! - `lastTokenAt`: its `message_delta`, which comes with the last token and the call's usage.
//! - `thought`: the call streamed thinking.
//!
//! They go out as `_meta.acpmux.timing` on the call's `usage_update` (`prompt_cache.rs`
//! `call_usage`), the record that already marks one main-loop call. Unix ms, on the daemon's clock,
//! the clock every record's `at` is on. A subagent's calls are not timed: its stream is its own.

use serde_json::{Value, json};
use std::sync::Mutex;

#[derive(Default)]
pub(super) struct ModelClock {
    state: Mutex<State>,
}

#[derive(Default, Clone, Copy)]
struct State {
    /// The request the next call answers.
    requested_at: Option<u64>,
    /// The call in flight's first byte.
    first_token_at: Option<u64>,
    /// The call in flight streamed thinking.
    thought: bool,
    /// When the last call ended.
    last_ended_at: Option<u64>,
}

impl ModelClock {
    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// A request went out at `at` (the prompt, its echo, tool results). A call cut off before its
    /// usage leaves nothing behind for the next one.
    pub(super) fn requested(&self, at: u64) {
        let mut state = self.state();
        *state = State {
            requested_at: Some(at),
            last_ended_at: state.last_ended_at,
            ..State::default()
        };
    }

    /// The call's first byte (`message_start`).
    pub(super) fn started(&self, at: u64) {
        let mut state = self.state();
        let requested =
            state.requested_at.or(state.last_ended_at).filter(|requested| *requested <= at);
        *state = State {
            requested_at: requested,
            first_token_at: Some(at),
            thought: false,
            last_ended_at: state.last_ended_at,
        };
    }

    /// The call streamed thinking.
    pub(super) fn thought(&self) {
        let mut state = self.state();
        if state.first_token_at.is_some() {
            state.thought = true;
        }
    }

    /// The call's last token and usage (`message_delta`) at `at`: its timing, once, or None for a
    /// call whose start was not seen.
    pub(super) fn ended(&self, at: u64) -> Option<Value> {
        let mut state = self.state();
        let first = state.first_token_at?;
        let mut timing = json!({"firstTokenAt": first, "lastTokenAt": at.max(first)});
        if let Some(requested) = state.requested_at {
            timing["requestAt"] = json!(requested);
        }
        if state.thought {
            timing["thought"] = json!(true);
        }
        *state = State { last_ended_at: Some(at), ..State::default() };
        Some(timing)
    }
}
