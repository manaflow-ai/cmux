//! `zstd-stream-v1` on the phone link: every acpmux message through one zstd stream kept for
//! the channel's life (cmux-mobile-link `zstd_stream.rs` has the envelope and the codec).
//!
//! Chat messages are almost all under `link_deflate`'s 16 KiB floor, so today they cross as
//! JSON text, 94–98 % of raw. One stream per channel keeps the last 1 MiB as context, and a
//! chat event mostly repeats what came before it (keys, session ids, paths): about 15 % of raw
//! on real acpmux session events, at about 3 µs a message.
//!
//! A phone that reads it opens `acpmux` with `args.compressions` listing `zstd-stream-v1`
//! (`"zstd-stream-v1,deflate"`; a JSON array of names reads the same) and still sends
//! `args.compression = "deflate"` for a host before this one, which reads only that.
//! A phone that sends no `compressions` gets deflate or text as before.
//!
//! The encoder lives on one dedicated blocking thread: messages are encoded in exactly the
//! order they are sent (each waits for its own envelope before the next is queued), and a
//! megabyte session list never blocks the runtime's workers.

use bytes::Bytes;
use cmux_mobile_link::zstd_stream::{self, StreamEncoder};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

/// Whether the channel's `args.compressions` ask for the zstd stream: a JSON array of names,
/// or the same names comma-separated (the phone's link args are string to string).
pub fn asked(args: &Value) -> bool {
    match args.get("compressions") {
        Some(Value::Array(names)) => names.iter().any(|name| name.as_str() == Some(zstd_stream::NAME)),
        Some(Value::String(names)) => names.split(',').any(|name| name.trim() == zstd_stream::NAME),
        _ => false,
    }
}

type Job = (String, oneshot::Sender<Option<Bytes>>);

/// One channel's stream: a thread owning the encoder, fed one message at a time.
pub struct LinkZstd {
    jobs: mpsc::Sender<Job>,
}

impl LinkZstd {
    pub fn new() -> Self {
        let (jobs, mut queue) = mpsc::channel::<Job>(1);
        std::thread::Builder::new()
            .name("link-zstd".into())
            .spawn(move || {
                let mut encoder = StreamEncoder::new();
                while let Some((text, reply)) = queue.blocking_recv() {
                    let made = encoder.envelope(text.as_bytes()).ok().map(Bytes::from);
                    let lost = made.is_none();
                    let _ = reply.send(made);
                    if lost {
                        return;
                    }
                }
            })
            .ok();
        Self { jobs }
    }

    /// `text` as its envelope, the stream's next message. None when the stream is lost (the
    /// encoder failed or its thread is gone): the channel must end, since the phone's
    /// decoder cannot skip a message.
    pub async fn frame(&self, text: String) -> Option<Bytes> {
        let (reply, made) = oneshot::channel();
        self.jobs.send((text, reply)).await.ok()?;
        made.await.ok().flatten()
    }
}

impl Default for LinkZstd {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_mobile_link::zstd_stream::{HEADER_BYTES, MARKER, StreamDecoder, header};

    /// Synthetic acpmux chat events shaped like a live session's: streamed message chunks,
    /// tool calls with paths and output, plan updates and turn ends, on a few sessions.
    pub(crate) fn chat_events(count: usize) -> Vec<String> {
        let sessions = [
            "0b6a4c1e-7d2f-4f39-9a51-2c8e5d7f1a30",
            "5f1d9e2a-3c4b-4e8f-b6a7-91d0c2e4f857",
            "c3e8a1b7-2d9f-4a6c-8e5b-7f0d1a2c3e4b",
        ];
        let files = ["src/link.rs", "src/services.rs", "Sources/App/ChatView.swift", "tests/test_link.py"];
        let words = [
            "the", "link", "message", "phone", "reads", "stream", "after", "test", "passes", "then",
            "change", "host", "channel", "envelope", "order", "context", "window", "bytes",
        ];
        (0..count)
            .map(|i| {
                let session = sessions[i % sessions.len()];
                let file = files[(i / 7) % files.len()];
                let text: String = (0..(8 + i % 23))
                    .map(|w| words[(i * 31 + w * 7) % words.len()])
                    .collect::<Vec<_>>()
                    .join(" ");
                let update = match i % 9 {
                    0 => serde_json::json!({"sessionUpdate": "tool_call", "toolCallId": format!("toolu_{:024x}", i * 7919),
                        "title": format!("Read {file}"), "kind": "read", "status": "pending",
                        "locations": [{"path": format!("/Users/me/work/cmux/{file}"), "line": i % 400}],
                        "rawInput": {"file_path": format!("/Users/me/work/cmux/{file}"), "offset": i % 400, "limit": 80}}),
                    1 => serde_json::json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("toolu_{:024x}", (i - 1) * 7919),
                        "status": "completed", "content": [{"type": "content", "content": {"type": "text",
                        "text": format!("{i:>5}\tfn {}() {{\n{i:>5}\t    {text};\n{i:>5}\t}}\n", words[i % words.len()])}}]}),
                    2 => serde_json::json!({"sessionUpdate": "plan", "entries": [
                        {"content": "Read the link code", "priority": "high", "status": "completed"},
                        {"content": format!("Change {file}"), "priority": "medium", "status": if i % 2 == 0 { "in_progress" } else { "pending" }},
                        {"content": "Run the tests", "priority": "medium", "status": "pending"}]}),
                    3 => serde_json::json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": text}}),
                    _ => serde_json::json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("{text} ")}}),
                };
                serde_json::json!({"jsonrpc": "2.0", "method": "session/update",
                    "params": {"sessionId": session, "update": update,
                    "_meta": {"seq": 10_000 + i, "ts": 1_764_000_000_000u64 + (i as u64) * 137}}})
                .to_string()
            })
            .collect()
    }

    #[tokio::test]
    async fn a_stream_of_chat_events_decodes_in_order() {
        let link = LinkZstd::new();
        let mut decoder = StreamDecoder::new();
        for text in chat_events(300) {
            let envelope = link.frame(text.clone()).await.expect("an envelope");
            assert_eq!(envelope[0], MARKER);
            let (text_len, _) = header(&envelope).unwrap();
            assert_eq!(decoder.decode(&envelope[HEADER_BYTES..], text_len).unwrap(), text.as_bytes());
        }
    }

    /// The scoreboard row "chat/history bytes on the phone link": over 1000 realistic chat
    /// events the stream sends at most 25 % of the raw JSON (deflate sends them all as text).
    #[tokio::test]
    async fn a_thousand_chat_events_cost_under_a_quarter_of_raw() {
        let fixture = include_str!("../tests/fixtures/chat-events.ndjson");
        let events: Vec<&str> = fixture.lines().filter(|line| !line.is_empty()).collect();
        assert!(events.len() >= 1000, "{} events", events.len());
        let link = LinkZstd::new();
        let (mut raw, mut sent, mut deflate) = (0usize, 0usize, 0usize);
        for text in &events {
            raw += text.len();
            sent += link.frame((*text).to_owned()).await.unwrap().len();
            deflate += crate::link_deflate::frame(true, text).await.len();
        }
        eprintln!(
            "raw {raw} B, zstd-stream {sent} B ({:.1} %), deflate {deflate} B ({:.1} %)",
            sent as f64 * 100.0 / raw as f64,
            deflate as f64 * 100.0 / raw as f64
        );
        assert!(sent * 4 <= raw, "zstd stream sent {sent} of {raw} bytes");
        assert!(deflate * 10 >= raw * 9, "per-message deflate leaves small messages as text");
    }

    #[test]
    fn the_fixture_is_the_generator_s() {
        let want: String = chat_events(1200).into_iter().map(|line| line + "\n").collect();
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/chat-events.ndjson");
        if std::env::var_os("CMUX_UPDATE_LINK_FIXTURES").is_some() {
            std::fs::write(path, &want).unwrap();
        }
        assert_eq!(std::fs::read_to_string(path).unwrap(), want, "CMUX_UPDATE_LINK_FIXTURES=1 rewrites it");
    }

    #[test]
    fn asked_only_by_a_compressions_list_naming_it() {
        // A new phone.
        assert!(asked(
            &serde_json::json!({"compression": "deflate", "compressions": ["zstd-stream-v1", "deflate"]})
        ));
        // An old phone: only `compression`; it keeps deflate (`link_deflate::asked`).
        let old = serde_json::json!({"compression": "deflate"});
        assert!(!asked(&old));
        assert!(crate::link_deflate::asked(&old));
        // The phone's string-to-string args.
        assert!(asked(
            &serde_json::json!({"compression": "deflate", "compressions": "zstd-stream-v1,deflate"})
        ));
        assert!(asked(&serde_json::json!({"compressions": "zstd-stream-v1"})));
        assert!(!asked(&serde_json::json!({"compressions": ["deflate"]})));
        assert!(!asked(&serde_json::json!({"compressions": "deflate,zstd-stream-v2"})));
        assert!(!asked(&serde_json::json!({"compressions": 1})));
        assert!(!asked(&Value::Null));
    }

    /// A host before this one reads only `compression`: the new phone's args still ask it for
    /// deflate, so it gets envelopes (0x00) or text, never a 0x01 it can't have made.
    #[tokio::test]
    async fn new_phone_args_on_an_old_host_get_deflate() {
        let args =
            serde_json::json!({"compression": "deflate", "compressions": ["zstd-stream-v1", "deflate"]});
        assert!(crate::link_deflate::asked(&args));
        let small = r#"{"jsonrpc":"2.0","id":1,"result":{}}"#;
        assert_eq!(&crate::link_deflate::frame(true, small).await[..], small.as_bytes());
        let large = chat_events(400).join("");
        assert_eq!(crate::link_deflate::frame(true, &large).await[0], crate::link_deflate::MARKER);
    }
}
