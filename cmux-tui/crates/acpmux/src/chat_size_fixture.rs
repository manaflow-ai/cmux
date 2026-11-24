//! One long coordinator chat of any size, shaped like a real one, for the chat size sweep
//! (`tests/god_daemon.rs` `chat_size_sweep`). Leo, 2026-11-19: "we need to be able to have
//! infinite chats, infinitely long chats ... on current day hardware". The goal record
//! (cmuxterm-hq#14331) asks that a chat's open, scroll, typing and memory at 100 MB, 1 GB and 4 GB
//! stay within 1.2x of a 1 MB chat's; this is the chat each of those sizes is.
//!
//! [`god_fixture`](crate::god_fixture)'s chat is four large records a turn. A real chat is
//! hundreds of small ones: a 56 MB Claude coordinator chat on a fleet VM (2026-11-19, counts and
//! sizes only) held 101,609 records in 131 turns, 555 bytes a record on average, about 775 a
//! turn. Per turn: 210 `claude.system.thinking_tokens` and 205 `agent_thought_chunk` of about
//! 300 bytes, 102 `agent_message_chunk` of about 350, 32 `claude.assistant` of about 1 KB,
//! 28 `tool_call_update` (most 256 B to 4 KB, a tail to 32 KB and beyond), 24
//! `claude.stream_event`, 21 `claude.stdin`, 18 `claude.user`, 18 `claude.control_response`,
//! 17 `claude.control_request`, 16 `tool_call`, 14 `usage_update`, 12 `claude.system.status`,
//! then one `user_message`, `session/prompt`, `turn_started`, `turn_end`, `turn_result` and
//! `usage_stats`. Turns vary: 302 records at the median, 1,549 at p90.
//!
//! [`write_chat`] writes that through the store (so segments are the store's own, 8 MiB each)
//! until the log reaches the bytes asked for, streaming: nothing of the log is held. Its text is
//! filler; every id is made here. The kind copies (`store/kind_index.rs`) are not made: the
//! daemon's first load makes them, as for a chat it has not read yet.

use serde_json::{Value, json};
use std::io;
use std::path::Path;
use std::sync::LazyLock;

const AT: u64 = 1_791_540_000_000;

/// The chat's acpmux id.
pub const CHAT_ID: &str = "01a1d5a0-0000-7000-8000-000000000001";

/// What [`write_chat`] wrote.
#[derive(Clone, Debug, Default)]
pub struct Written {
    pub id: String,
    /// The log's bytes, as its lines are.
    pub bytes: u64,
    pub records: u64,
    pub turns: u64,
    pub last_seq: u64,
    /// Tool outputs written, and the largest.
    pub tool_outputs: u64,
    pub largest_output: u64,
}

/// A small deterministic generator (splitmix64): the same chat for the same size, every run.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// In `lo..=hi`.
    fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next() % (hi - lo + 1)
    }

    /// True with chance `n` in `of`.
    fn one_in(&mut self, n: u64, of: u64) -> bool {
        self.next() % of < n
    }

    /// A size whose log2 bucket is drawn from `buckets` (`(log2, weight)`), uniform within it.
    fn log2_size(&mut self, buckets: &[(u32, u64)]) -> usize {
        let total: u64 = buckets.iter().map(|(_, w)| w).sum();
        let mut pick = self.next() % total;
        for (bucket, weight) in buckets {
            if pick < *weight {
                return self.range(1 << bucket, (2u64 << bucket) - 1) as usize;
            }
            pick -= weight;
        }
        buckets.first().map_or(1, |(bucket, _)| 1 << bucket)
    }
}

/// Filler words, 256 KiB of them: every text is a slice of it.
static FILLER: LazyLock<String> = LazyLock::new(|| {
    const WORDS: &[&str] = &[
        "the", "lane", "daemon", "chat", "page", "scroll", "build", "test", "merge", "review",
        "segment", "index", "record", "prompt", "turn", "agent", "tool", "output", "fixture",
        "runner", "commit", "branch", "green", "cargo", "release", "open", "attach", "row", "seq",
        "bytes", "latency", "memory", "and", "of", "to", "a", "in", "is", "that", "it", "next",
    ];
    let mut rng = Rng(7);
    let mut text = String::with_capacity(256 << 10);
    while text.len() < 256 << 10 {
        text.push_str(WORDS.get(rng.next() as usize % WORDS.len()).copied().unwrap_or("the"));
        text.push(if rng.one_in(1, 12) { '\n' } else { ' ' });
    }
    text
});

/// `len` bytes of filler from a place `rng` picks (ASCII, so any cut is a char boundary).
fn text(rng: &mut Rng, len: usize) -> &'static str {
    let filler = FILLER.as_str();
    let len = len.min(filler.len());
    let at = rng.next() as usize % (filler.len() - len + 1);
    filler.get(at..at + len).unwrap_or_default()
}

/// Filler of a length in `lo..=hi`.
fn text_between(rng: &mut Rng, lo: u64, hi: u64) -> &'static str {
    let len = rng.range(lo, hi) as usize;
    text(rng, len)
}

fn uuid(tag: u64, n: u64) -> String {
    format!("{:08x}-0000-4000-8000-{n:012x}", tag)
}

/// Bytes of `value` as one JSON line, without keeping it.
fn line_len(value: &crate::store::EventRecord) -> u64 {
    struct Count(u64);
    impl io::Write for Count {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0 += buf.len() as u64;
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut count = Count(0);
    let _ = serde_json::to_writer(&mut count, value);
    count.0 + 1
}

/// Tool output sizes: the calibration chat's `tool_call_update` histogram, with the tail the task
/// asks for (100 B to 100 KB).
const OUTPUT_BUCKETS: &[(u32, u64)] = &[
    (7, 60),
    (8, 110),
    (9, 480),
    (10, 180),
    (11, 120),
    (12, 70),
    (13, 26),
    (14, 8),
    (15, 3),
    (16, 1),
];

/// Prompt sizes: the calibration chat's `user_message` histogram.
const PROMPT_BUCKETS: &[(u32, u64)] = &[(8, 26), (9, 80), (10, 13), (11, 9), (12, 3)];

/// Writes the chat to `store` as `id` until its log holds `bytes`, a turn at a time: see the
/// module text for its shape.
pub fn append_chat(store: &dyn crate::store::Store, id: &str, bytes: u64) -> io::Result<Written> {
    let mut rng = Rng(bytes ^ 0x5eed);
    let mut w = Written { id: id.to_owned(), ..Written::default() };
    let put = |w: &mut Written, kind: &str, dir: &str, msg: Value| -> io::Result<()> {
        w.last_seq += 1;
        let rec = crate::store::EventRecord {
            seq: w.last_seq,
            at: AT + w.last_seq * 40,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        w.bytes += line_len(&rec);
        w.records += 1;
        store.append(id, &rec).map_err(|e| io::Error::other(e.to_string()))
    };
    let update = |update: Value| {
        json!({"jsonrpc": "2.0", "method": "session/update",
               "params": {"sessionId": id, "update": update}})
    };
    let claude_session = uuid(0xc1a0de, 1);
    let mut rpc_id = 0u64;
    let mut call = 0u64;
    while w.bytes < bytes.max(1) {
        let turn = w.turns;
        w.turns += 1;
        let (turn_id, prompt_id) = (uuid(0x7, turn), uuid(0x9, turn));
        let prompt = {
            let n = rng.log2_size(PROMPT_BUCKETS);
            text(&mut rng, n)
        }
        .to_owned();
        let line: String = prompt.chars().take(200).collect();
        put(
            &mut w,
            "user_message",
            "mux",
            json!({"client": "cmux-next-chat", "cloudMobile": false, "control": "local",
                   "inlineParts": [{"kind": "text", "text": prompt}], "promptId": prompt_id,
                   "text": prompt, "turnId": turn_id}),
        )?;
        rpc_id += 1;
        put(
            &mut w,
            "session/prompt",
            "out",
            json!({"id": rpc_id, "jsonrpc": "2.0", "method": "session/prompt",
                   "params": {"prompt": [{"text": prompt, "type": "text"}], "sessionId": claude_session}}),
        )?;
        put(
            &mut w,
            "turn_started",
            "mux",
            json!({"client": "cmux-next-chat", "cloudMobile": false, "control": "local",
                   "persons": false, "prompt": line, "promptId": prompt_id, "promptLine": line,
                   "trigger": false, "trustGate": false, "turnId": turn_id}),
        )?;
        // Steps of thinking then a tool call: 16 on average, a long tail (p90 about 4x the
        // median, as the calibration chat's records per turn).
        let steps = if rng.one_in(1, 8) { rng.range(30, 90) } else { rng.range(2, 14) };
        for _ in 0..steps {
            let message = uuid(0xa5, rng.next() >> 16);
            for _ in 0..rng.range(6, 20) {
                put(
                    &mut w,
                    "claude.system.thinking_tokens",
                    "in",
                    json!({"estimated_tokens": rng.range(10, 9000), "estimated_tokens_delta": rng.range(1, 40),
                           "session_id": claude_session, "subtype": "thinking_tokens", "type": "system",
                           "user_message_uuid": prompt_id, "uuid": uuid(0x11, rng.next() >> 16)}),
                )?;
                let chunk = text_between(&mut rng, 1, 60);
                put(
                    &mut w,
                    "agent_thought_chunk",
                    "in",
                    update(json!({"content": {"text": chunk, "type": "text"},
                                  "sessionUpdate": "agent_thought_chunk"})),
                )?;
            }
            for _ in 0..rng.range(1, 2) {
                put(
                    &mut w,
                    "claude.stream_event",
                    "in",
                    json!({"api_message_id": message, "event": {"type": "content_block_delta",
                           "index": 0, "delta": {"type": "thinking_delta", "thinking": text(&mut rng, 200)}},
                           "parent_tool_use_id": null, "session_id": claude_session,
                           "thinking_display": "summarized", "type": "stream_event",
                           "user_message_uuid": prompt_id, "uuid": uuid(0x12, rng.next() >> 16)}),
                )?;
            }
            call += 1;
            let tool = format!("toolu_{call:024}");
            for _ in 0..2 {
                put(
                    &mut w,
                    "claude.assistant",
                    "in",
                    json!({"_acpmux": {"bodiesLeftOut": 1}, "message": {"content": [{"type": "tool_use",
                           "id": tool, "name": "Bash"}], "id": message, "model": "claude-opus-5-5",
                           "role": "assistant", "stop_reason": null, "type": "message",
                           "usage": {"cache_creation_input_tokens": rng.range(0, 9000),
                                     "cache_read_input_tokens": rng.range(0, 190_000),
                                     "input_tokens": rng.range(1, 50), "output_tokens": rng.range(1, 3000),
                                     "service_tier": "standard"}},
                           "parent_tool_use_id": null, "session_id": claude_session, "type": "assistant",
                           "uuid": uuid(0x13, rng.next() >> 16), "pad": text(&mut rng, 300)}),
                )?;
            }
            let title = text_between(&mut rng, 8, 120).to_owned();
            put(
                &mut w,
                "tool_call",
                "in",
                update(json!({"_meta": {"claude": {"tool": "Bash"}}, "kind": "execute",
                              "rawInput": {"command": title, "description": text(&mut rng, 40)},
                              "sessionUpdate": "tool_call", "status": "pending", "title": title,
                              "toolCallId": tool})),
            )?;
            put(
                &mut w,
                "claude.control_request",
                "in",
                json!({"request": {"callback_id": format!("hook_{call}"), "input": {"cwd": "/home/agent/work",
                       "hook_event_name": "PreToolUse", "permission_mode": "bypassPermissions",
                       "prompt_id": prompt_id, "session_id": claude_session,
                       "tool_input": {"command": title}, "tool_name": "Bash", "tool_use_id": tool,
                       "transcript_path": "/home/agent/.claude/projects/-home-agent-work/session.jsonl"},
                       "subtype": "hook_callback", "tool_use_id": tool},
                       "request_id": uuid(0x14, call), "type": "control_request"}),
            )?;
            put(
                &mut w,
                "claude.stdin",
                "out",
                json!({"response": {"request_id": uuid(0x14, call), "response": {"continue": true},
                       "subtype": "success"}, "type": "control_response"}),
            )?;
            put(
                &mut w,
                "claude.control_response",
                "in",
                json!({"response": {"request_id": uuid(0x15, call), "subtype": "success"},
                       "type": "control_response"}),
            )?;
            put(
                &mut w,
                "tool_call_update",
                "in",
                update(json!({"_meta": {"claude": {"tool": "Bash"}}, "kind": "execute",
                              "sessionUpdate": "tool_call_update", "status": "in_progress",
                              "title": title, "toolCallId": tool})),
            )?;
            let output = rng.log2_size(OUTPUT_BUCKETS);
            w.tool_outputs += 1;
            w.largest_output = w.largest_output.max(output as u64);
            put(
                &mut w,
                "tool_call_update",
                "in",
                update(
                    json!({"_meta": {"claude": {"tool": "Bash"}}, "sessionUpdate": "tool_call_update",
                              "status": "completed", "toolCallId": tool, "rawOutput": {"exit_code": 0},
                              "content": [{"type": "content", "content": {"type": "text",
                                           "text": text(&mut rng, output)}}]}),
                ),
            )?;
            put(
                &mut w,
                "claude.user",
                "in",
                json!({"_acpmux": {"bodiesLeftOut": 1}, "message": {"content": [{"type": "tool_result",
                       "tool_use_id": tool}], "role": "user"}, "parent_tool_use_id": null,
                       "session_id": claude_session, "type": "user", "uuid": uuid(0x16, call)}),
            )?;
            put(
                &mut w,
                "usage_update",
                "in",
                update(
                    json!({"_meta": {"acpmux": {"cacheExpiresAt": AT + turn * 60_000, "call": true}},
                              "cachedReadTokens": rng.range(0, 190_000), "cachedWriteTokens": rng.range(0, 9000),
                              "inputTokens": rng.range(1, 50), "outputTokens": rng.range(1, 3000),
                              "sessionUpdate": "usage_update", "size": 200_000, "used": rng.range(20_000, 190_000)}),
                ),
            )?;
            if rng.one_in(3, 4) {
                put(
                    &mut w,
                    "claude.system.status",
                    "in",
                    json!({"permissionMode": "bypassPermissions", "session_id": claude_session,
                           "status": null, "subtype": "status", "type": "system",
                           "uuid": uuid(0x17, rng.next() >> 16)}),
                )?;
            }
        }
        // The answer, streamed in small chunks.
        let message = uuid(0xa6, turn);
        for _ in 0..rng.range(20, 180) {
            put(
                &mut w,
                "agent_message_chunk",
                "in",
                update(json!({"content": {"text": text_between(&mut rng, 2, 40), "type": "text"},
                              "messageId": message, "sessionUpdate": "agent_message_chunk"})),
            )?;
        }
        put(
            &mut w,
            "claude.result.success",
            "in",
            json!({"duration_ms": rng.range(1000, 900_000), "is_error": false, "num_turns": steps,
                   "result": text(&mut rng, 2400), "session_id": claude_session,
                   "stop_reason": "end_turn", "subtype": "success", "type": "result",
                   "uuid": uuid(0x18, turn)}),
        )?;
        put(
            &mut w,
            "response",
            "in",
            json!({"id": rpc_id, "jsonrpc": "2.0", "result": {"stopReason": "end_turn"}}),
        )?;
        let turn_seq = w.last_seq;
        put(
            &mut w,
            "turn_end",
            "mux",
            json!({"stopReason": "end_turn", "turnId": turn_id, "turnSeq": turn_seq}),
        )?;
        put(
            &mut w,
            "turn_result",
            "mux",
            json!({"cacheReadTokens": rng.range(0, 1 << 24), "cacheWriteTokens": rng.range(0, 1 << 20),
                   "costUsd": 0.25, "inputTokens": rng.range(1, 900), "model": "claude-opus-5-5",
                   "outputTokens": rng.range(1, 90_000), "pendingPermissions": 0, "promptId": prompt_id,
                   "status": "completed", "stopReason": "end_turn", "trigger": false,
                   "turnCount": turn + 1, "turnId": turn_id, "turnSeq": turn_seq, "unread": false}),
        )?;
        put(
            &mut w,
            "usage_stats",
            "mux",
            json!({"autocompact": "capped", "autocompactCap": 160_000, "cacheReadShare24h": 0.9,
                   "calls24h": turn * 16, "contextTokens": rng.range(20_000, 190_000),
                   "contextWindow": 200_000, "launcher": "claude", "updatedAt": AT + turn * 60_000}),
        )?;
    }
    Ok(w)
}

/// An acpmux home at `home` holding the one chat of about `bytes` ([`CHAT_ID`]), its folder under
/// `work`, and its `session.json` agreeing with its log (`lastSeq`, `eventCount`, `turnCount`).
pub fn write_chat(home: &Path, work: &Path, bytes: u64) -> io::Result<Written> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store =
        crate::store::open(&cfg.store, home).map_err(|e| io::Error::other(e.to_string()))?;
    let written = append_chat(store.as_ref(), CHAT_ID, bytes)?;
    std::fs::create_dir_all(work)?;
    let cwd = work.to_string_lossy().into_owned();
    let mut meta = crate::god_fixture::session_meta(
        CHAT_ID,
        "coordinator",
        &cwd,
        &crate::god_fixture::agent_session_id(1),
        written.last_seq,
        AT,
    );
    if let Some(fields) = meta.as_object_mut() {
        fields.insert("turnCount".into(), json!(written.turns));
        fields.insert("updatedAt".into(), json!(AT + written.last_seq * 40));
    }
    let meta = serde_json::from_value(meta).map_err(io::Error::other)?;
    store.save(&meta).map_err(|e| io::Error::other(e.to_string()))?;
    store.flush().map_err(|e| io::Error::other(e.to_string()))?;
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 4 MB chat is the calibration chat's shape: small records, hundreds a turn, its bytes
    /// within a turn of those asked for, and `session.json` agreeing with the log.
    #[test]
    fn a_chat_is_many_small_records_and_its_meta_agrees() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("acpmux");
        let asked = 4 << 20;
        let w = write_chat(&home, &dir.path().join("work"), asked).unwrap();
        let per_record = w.bytes / w.records;
        assert!((250..=1200).contains(&per_record), "{per_record} bytes a record: {w:?}");
        let per_turn = w.records / w.turns;
        assert!((150..=2500).contains(&per_turn), "{per_turn} records a turn: {w:?}");
        assert!(w.bytes >= asked && w.bytes < asked + (8 << 20), "{w:?}");
        let on_disk: u64 = std::fs::read_dir(home.join("sessions").join(CHAT_ID).join("events"))
            .unwrap()
            .map(|e| e.unwrap().metadata().unwrap().len())
            .sum();
        assert_eq!(on_disk, w.bytes, "the counted bytes are the log's");
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        let store = crate::store::open(&cfg.store, &home).unwrap();
        let meta = store.load(CHAT_ID).unwrap().unwrap();
        assert_eq!(meta.last_seq, w.last_seq);
        let mut prompts = 0;
        store
            .scan_kinds(CHAT_ID, &["user_message"], &mut |_| {
                prompts += 1;
                true
            })
            .unwrap();
        assert_eq!(prompts, w.turns);
    }

    #[test]
    fn the_same_size_is_the_same_chat() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let wa = write_chat(&a.path().join("h"), &a.path().join("w"), 1 << 20).unwrap();
        let wb = write_chat(&b.path().join("h"), &b.path().join("w"), 1 << 20).unwrap();
        assert_eq!((wa.bytes, wa.records, wa.turns), (wb.bytes, wb.records, wb.turns));
    }
}
