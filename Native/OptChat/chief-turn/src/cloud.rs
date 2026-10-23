//! The Cloud Chief turn's stream protocol: Claude Code's stream-json lines as
//! the events the Worker's `ccNotes` takes (`backend/apps/api/src/chief-brain-cc/turn.ts`),
//! one generation per model message, and the turn's result.
//!
//! Events (each with `gen`, the model message's number from 0):
//! `text_start`, `text_delta {delta}`, `text_done {text}`, `thinking_start`,
//! `thinking_delta {delta}`, `tool {id, name, input}`, `tool_done {id,
//! error}`, `done`. A step boundary (`text_done`, `tool`, `done`) is sent at
//! once; the rest within the runner's batch window.

use std::collections::HashMap;

use serde_json::{Map, Value, json};

use crate::Usage;
use crate::stream::{Block, Delta, Line, StreamEvent, is_subagent};

/// One event for the Worker, and whether it ends a step (send at once).
#[derive(Debug, Clone, PartialEq)]
pub struct Note {
    pub event: Value,
    pub now: bool,
}

#[derive(Debug)]
enum Open {
    Text(String),
    Thinking,
    Tool {
        id: String,
        name: String,
        json: String,
    },
}

/// The turn's fold of Claude Code's lines (the state `run.mjs` kept).
#[derive(Debug)]
pub struct TurnStream {
    generation: i64,
    last_gen: i64,
    blocks: HashMap<Option<u64>, Open>,
    result: Option<Value>,
    /// Set by the first content delta (ms from the turn's start, as the
    /// caller's clock says).
    first_token_ms: Option<u64>,
}

impl Default for TurnStream {
    fn default() -> Self {
        TurnStream {
            generation: -1,
            last_gen: 0,
            blocks: HashMap::new(),
            result: None,
            first_token_ms: None,
        }
    }
}

/// How the turn ended, for [`TurnStream::finish`].
pub struct Exit<'a> {
    pub run: &'a str,
    pub model: &'a str,
    /// Claude Code's exit code; None when a signal ended it.
    pub code: Option<i32>,
    /// Signal number when there was no code.
    pub signal: Option<i32>,
    /// The end of Claude Code's stderr.
    pub stderr: &'a str,
    pub total_ms: u64,
}

impl TurnStream {
    pub fn new() -> Self {
        Self::default()
    }

    /// The `first_token_ms` so far.
    pub fn first_token_ms(&self) -> Option<u64> {
        self.first_token_ms
    }

    /// One stream-json line; `elapsed_ms` is the time since the turn started.
    /// A subagent's lines (Claude Code's Task tool) are not the turn's.
    pub fn line(&mut self, line: &Value, elapsed_ms: u64) -> Vec<Note> {
        let mut out = Vec::new();
        if is_subagent(line) {
            return out;
        }
        let cur = |s: &Self| json!(s.generation);
        let note = |out: &mut Vec<Note>, mut ev: Map<String, Value>, g: Value, now: bool| {
            ev.insert("gen".into(), g);
            out.push(Note {
                event: Value::Object(ev),
                now,
            });
        };
        let obj = |v: Value| match v {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        match Line::parse(line) {
            Line::Result(r) => self.result = Some(r.clone()),
            Line::User { tool_results, .. } => {
                for t in tool_results {
                    note(
                        &mut out,
                        obj(json!({"type":"tool_done","id":t.id,"error":t.error})),
                        cur(self),
                        false,
                    );
                }
            }
            Line::Stream(ev) => match ev {
                StreamEvent::MessageStart { .. } => self.generation += 1,
                StreamEvent::MessageStop => {
                    note(&mut out, obj(json!({"type":"done"})), cur(self), true)
                }
                StreamEvent::BlockStart { index, block } => match block {
                    Block::Text => {
                        self.blocks.insert(index, Open::Text(String::new()));
                        note(
                            &mut out,
                            obj(json!({"type":"text_start"})),
                            cur(self),
                            false,
                        );
                    }
                    Block::Thinking => {
                        self.blocks.insert(index, Open::Thinking);
                        note(
                            &mut out,
                            obj(json!({"type":"thinking_start"})),
                            cur(self),
                            false,
                        );
                    }
                    Block::Tool { id, name } => {
                        self.blocks.insert(
                            index,
                            Open::Tool {
                                id,
                                name,
                                json: String::new(),
                            },
                        );
                    }
                    Block::Other => {}
                },
                StreamEvent::BlockDelta { index, delta } => {
                    let g = cur(self);
                    let Some(b) = self.blocks.get_mut(&index) else {
                        return out;
                    };
                    match (b, delta) {
                        (Open::Text(text), Delta::Text(d)) => {
                            text.push_str(&d);
                            note(
                                &mut out,
                                obj(json!({"type":"text_delta","delta":d})),
                                g,
                                false,
                            );
                        }
                        (Open::Thinking, Delta::Thinking(d)) => {
                            note(
                                &mut out,
                                obj(json!({"type":"thinking_delta","delta":d})),
                                g,
                                false,
                            );
                        }
                        (Open::Tool { json, .. }, Delta::InputJson(d)) => json.push_str(&d),
                        _ => return out,
                    }
                    if self.first_token_ms.is_none() {
                        self.first_token_ms = Some(elapsed_ms);
                    }
                }
                StreamEvent::BlockStop { index } => match self.blocks.remove(&index) {
                    Some(Open::Text(text)) if !text.trim().is_empty() => {
                        self.last_gen = self.generation;
                        note(
                            &mut out,
                            obj(json!({"type":"text_done","text":text})),
                            cur(self),
                            true,
                        );
                    }
                    Some(Open::Tool { id, name, json }) => {
                        let input = serde_json::from_str::<Value>(if json.is_empty() {
                            "{}"
                        } else {
                            &json
                        })
                        .unwrap_or_else(|_| json!({}));
                        note(
                            &mut out,
                            obj(json!({"type":"tool","id":id,"name":name,"input":input})),
                            cur(self),
                            true,
                        );
                    }
                    _ => {}
                },
                StreamEvent::Other => {}
            },
            Line::Assistant(_) | Line::Other => {}
        }
        out
    }

    /// The turn's result (`/run/chief/<run>.out` and the last notes post):
    /// done when Claude Code sent a result that is not an error and exited 0.
    pub fn finish(&self, exit: Exit<'_>) -> Value {
        let r = self.result.as_ref();
        let ok = r.is_some_and(|r| r.get("is_error") != Some(&Value::Bool(true)))
            && exit.code == Some(0);
        let present = |k: &str| r.and_then(|r| r.get(k)).filter(|v| !v.is_null());
        let as_text = |v: &Value| {
            v.as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| v.to_string())
        };
        let u = Usage::parse_lenient(r.and_then(|r| r.get("usage")));
        let mut out = Map::new();
        out.insert("run".into(), json!(exit.run));
        out.insert("status".into(), json!(if ok { "done" } else { "failed" }));
        out.insert(
            "reply".into(),
            json!(if ok {
                present("result").map(as_text).unwrap_or_default()
            } else {
                String::new()
            }),
        );
        if !ok {
            let why = present("result")
                .or_else(|| present("subtype"))
                .map(as_text)
                .unwrap_or_else(|| {
                    let how = match (exit.code, exit.signal) {
                        (Some(c), _) => c.to_string(),
                        (None, Some(s)) => format!("on signal {s}"),
                        _ => "null".to_owned(),
                    };
                    format!("claude exited {how}: {}", tail_chars(exit.stderr, 300))
                });
            out.insert(
                "error".into(),
                json!(why.chars().take(500).collect::<String>()),
            );
        }
        out.insert("model".into(), json!(exit.model));
        out.insert(
            "usage".into(),
            json!({"input": u.input, "output": u.output, "cache_read": u.cache_read, "cache_write": u.cache_write}),
        );
        out.insert("first_token_ms".into(), json!(self.first_token_ms));
        out.insert("last_gen".into(), json!(self.last_gen));
        out.insert("total_ms".into(), json!(exit.total_ms));
        Value::Object(out)
    }
}

/// The last `n` characters of `s`.
pub fn tail_chars(s: &str, n: usize) -> &str {
    let count = s.chars().count();
    if count <= n {
        return s;
    }
    let skip = count - n;
    let at = s
        .char_indices()
        .nth(skip)
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    &s[at..]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(lines: &[Value]) -> (TurnStream, Vec<Note>) {
        let mut t = TurnStream::new();
        let mut out = Vec::new();
        for (i, l) in lines.iter().enumerate() {
            out.extend(t.line(l, 10 * i as u64));
        }
        (t, out)
    }

    fn se(e: Value) -> Value {
        json!({"type":"stream_event","event":e})
    }

    #[test]
    fn a_turn_with_a_tool_then_a_reply() {
        let lines = [
            json!({"type":"system","subtype":"init"}),
            se(json!({"type":"message_start","message":{"id":"m1"}})),
            se(json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking"}})),
            se(
                json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}),
            ),
            se(json!({"type":"content_block_stop","index":0})),
            se(
                json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash"}}),
            ),
            se(
                json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}),
            ),
            se(
                json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}),
            ),
            se(json!({"type":"content_block_stop","index":1})),
            se(json!({"type":"message_stop"})),
            json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1"}]}}),
            se(json!({"type":"message_start","message":{"id":"m2"}})),
            se(json!({"type":"content_block_start","index":0,"content_block":{"type":"text"}})),
            se(
                json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi "}}),
            ),
            se(
                json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}),
            ),
            se(json!({"type":"content_block_stop","index":0})),
            se(json!({"type":"message_stop"})),
            json!({"type":"result","subtype":"success","is_error":false,"result":"Hi there",
                   "usage":{"input_tokens":5,"output_tokens":7,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}),
        ];
        let (t, notes) = feed(&lines);
        let evs: Vec<Value> = notes.iter().map(|n| n.event.clone()).collect();
        assert_eq!(
            evs,
            vec![
                json!({"gen":0,"type":"thinking_start"}),
                json!({"gen":0,"type":"thinking_delta","delta":"plan"}),
                json!({"gen":0,"type":"tool","id":"toolu_1","name":"Bash","input":{"command":"ls"}}),
                json!({"gen":0,"type":"done"}),
                json!({"gen":0,"type":"tool_done","id":"toolu_1","error":false}),
                json!({"gen":1,"type":"text_start"}),
                json!({"gen":1,"type":"text_delta","delta":"Hi "}),
                json!({"gen":1,"type":"text_delta","delta":"there"}),
                json!({"gen":1,"type":"text_done","text":"Hi there"}),
                json!({"gen":1,"type":"done"}),
            ]
        );
        let now: Vec<bool> = notes.iter().map(|n| n.now).collect();
        assert_eq!(
            now,
            vec![
                false, false, true, true, false, false, false, false, true, true
            ]
        );
        // The first content delta is line 3 (10 ms per line in `feed`).
        assert_eq!(t.first_token_ms(), Some(30));
        let r = t.finish(Exit {
            run: "run_1",
            model: "claude-opus",
            code: Some(0),
            signal: None,
            stderr: "",
            total_ms: 900,
        });
        assert_eq!(
            r,
            json!({"run":"run_1","status":"done","reply":"Hi there","model":"claude-opus",
                   "usage":{"input":5,"output":7,"cache_read":100,"cache_write":20},
                   "first_token_ms":30,"last_gen":1,"total_ms":900})
        );
    }

    #[test]
    fn a_subagents_lines_are_not_the_turns() {
        let (t, notes) = feed(&[
            json!({"type":"stream_event","parent_tool_use_id":"toolu_task","event":{"type":"message_start","message":{"id":"s"}}}),
            se(json!({"type":"message_start","message":{"id":"m"}})),
            se(json!({"type":"message_stop"})),
        ]);
        assert_eq!(
            notes,
            vec![Note {
                event: json!({"gen":0,"type":"done"}),
                now: true
            }]
        );
        assert_eq!(t.first_token_ms(), None);
    }

    #[test]
    fn whitespace_text_and_bad_tool_json() {
        let (_, notes) = feed(&[
            se(json!({"type":"message_start","message":{"id":"m"}})),
            se(json!({"type":"content_block_start","index":0,"content_block":{"type":"text"}})),
            se(
                json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"  "}}),
            ),
            se(json!({"type":"content_block_stop","index":0})),
            se(
                json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"X"}}),
            ),
            se(
                json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{bad"}}),
            ),
            se(json!({"type":"content_block_stop","index":1})),
        ]);
        let types: Vec<&str> = notes
            .iter()
            .map(|n| n.event["type"].as_str().unwrap())
            .collect();
        assert_eq!(types, vec!["text_start", "text_delta", "tool"]);
        assert_eq!(notes[2].event["input"], json!({}));
    }

    #[test]
    fn failures_say_why() {
        let t = TurnStream::new();
        let r = t.finish(Exit {
            run: "run_2",
            model: "m",
            code: Some(1),
            signal: None,
            stderr: "boom",
            total_ms: 5,
        });
        assert_eq!(r["status"], "failed");
        assert_eq!(r["reply"], "");
        assert_eq!(r["error"], "claude exited 1: boom");
        assert_eq!(r["first_token_ms"], Value::Null);
        assert_eq!(r["last_gen"], 0);

        let (t, _) = feed(&[json!({"type":"result","is_error":true,"subtype":"error_max_turns"})]);
        let r = t.finish(Exit {
            run: "run_3",
            model: "m",
            code: Some(0),
            signal: None,
            stderr: "",
            total_ms: 5,
        });
        assert_eq!(r["error"], "error_max_turns");

        let (t, _) = feed(&[json!({"type":"result","is_error":false,"result":"ok"})]);
        let r = t.finish(Exit {
            run: "run_4",
            model: "m",
            code: None,
            signal: Some(9),
            stderr: "",
            total_ms: 5,
        });
        assert_eq!(r["status"], "failed");
        assert_eq!(r["error"], "ok");
    }

    #[test]
    fn tail_chars_counts_characters() {
        assert_eq!(tail_chars("héllo", 3), "llo");
        assert_eq!(tail_chars("ab", 5), "ab");
    }
}
