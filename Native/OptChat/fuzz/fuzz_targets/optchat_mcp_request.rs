//! The OptChat Chief's MCP server (`mcp::handle`): the JSON-RPC lines a turn's
//! harness sends on stdio (`initialize`, `tools/list`, `tools/call` with any
//! tool name and arguments, unknown methods), each parsed into a tool call
//! (`tools::Call::parse`) and answered by a recording backend instead of the
//! host socket. The first byte picks a Chief's server or a subagent's.
//!
//! Invariants past "no panic":
//! - a message without `id` gets no answer; one with an id gets one JSON-RPC
//!   2.0 answer with that id and exactly one of `result` or `error`;
//! - a `tools/call` answer is MCP content with a boolean `isError`;
//! - a subagent's server never forwards a tool that only the Chief may call
//!   (spawn, react, reply, send, transcript, stop, sleep, control, profile,
//!   chiefs), whatever the arguments.
#![no_main]

use std::cell::RefCell;

use libfuzzer_sys::fuzz_target;
use optchat_chief::mcp::{Backend, handle};
use optchat_chief::tools::Call;
use serde_json::Value;

/// The most lines one input feeds.
const MAX_LINES: usize = 64;

struct Recorder {
    subagent: bool,
    calls: RefCell<Vec<Call>>,
}

impl Backend for Recorder {
    fn call(&self, call: Call) -> Result<String, String> {
        let answer = format!("{call:?}");
        self.calls.borrow_mut().push(call);
        if answer.len() % 3 == 0 {
            Err(answer)
        } else {
            Ok(answer)
        }
    }

    fn subagent(&self) -> bool {
        self.subagent
    }

    /// The real answer reads the Chief home on disk; not the code under test.
    fn version(&self) -> Result<String, String> {
        Ok("optchat-fuzz".into())
    }
}

fn chief_only(call: &Call) -> bool {
    matches!(
        call,
        Call::Spawn { .. }
            | Call::React { .. }
            | Call::Reply { .. }
            | Call::Send(_)
            | Call::Transcript { .. }
            | Call::Stop
            | Call::Sleep(_)
            | Call::Control(_)
            | Call::Profile { .. }
            | Call::Chiefs { .. }
    )
}

fuzz_target!(|data: &[u8]| {
    let Some((&flags, rest)) = data.split_first() else {
        return;
    };
    let Ok(text) = std::str::from_utf8(rest) else {
        return;
    };
    let backend = Recorder {
        subagent: flags & 1 == 1,
        calls: RefCell::new(Vec::new()),
    };
    for line in text.lines().take(MAX_LINES) {
        let Ok(message) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let answer = handle(&message, &backend);
        let Some(id) = message.get("id") else {
            assert!(answer.is_none(), "a notification was answered: {answer:?}");
            continue;
        };
        let answer = answer.expect("a request with an id is answered");
        assert_eq!(answer["jsonrpc"], "2.0", "not JSON-RPC 2.0: {answer}");
        assert_eq!(&answer["id"], id, "the answer names another request");
        let result = answer.get("result");
        assert!(
            result.is_some() != answer.get("error").is_some(),
            "result and error: {answer}"
        );
        if message.get("method").and_then(Value::as_str) == Some("tools/call") {
            let result = result.expect("a tool call answers with a result");
            assert!(
                result["isError"].is_boolean(),
                "a tool answer without isError: {result}"
            );
            assert!(
                result["content"][0]["text"].is_string(),
                "a tool answer without text: {result}"
            );
        }
    }
    if backend.subagent {
        let calls = backend.calls.borrow();
        assert!(
            !calls.iter().any(chief_only),
            "a subagent reached a Chief tool: {calls:?}"
        );
    }
});
