//! What the log keeps of Claude's raw assistant and user lines (`logged_bodies.rs`).

use super::*;
use std::io::{BufRead, BufReader};

/// A tool result's line keeps its block's ids and error flag; Claude Code's copies of the output
/// and a string prompt go, noted in bytes. A line of another kind, or one with nothing to leave
/// out, is untouched.
#[test]
fn a_user_lines_tool_output_goes_and_its_ids_stay() {
    let mut line = json!({"type": "user", "session_id": "cc-1", "parent_tool_use_id": "toolu_0",
        "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "is_error": true, "content": "boom"}]},
        "tool_use_result": "Error: boom"});
    leave_out_bodies("claude.user", &mut line);
    assert_eq!(
        line,
        json!({"type": "user", "session_id": "cc-1", "parent_tool_use_id": "toolu_0",
            "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_1", "is_error": true}]},
            "_acpmux": {"bodiesLeftOut": 26}})
    );
    let mut prompt = json!({"type": "user", "isReplay": true, "message": {"content": "hi"}});
    leave_out_bodies("claude.user", &mut prompt);
    assert_eq!(
        prompt,
        json!({"type": "user", "isReplay": true, "message": {"content": ""},
            "_acpmux": {"bodiesLeftOut": 4}})
    );
    let init = json!({"type": "system", "subtype": "init", "tools": ["Bash"]});
    let mut same = init.clone();
    leave_out_bodies("claude.system.init", &mut same);
    assert_eq!(same, init);
    let bare =
        json!({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t"}]}});
    let mut same = bare.clone();
    leave_out_bodies("claude.assistant", &mut same);
    assert_eq!(same, bare);
}

/// What each reader takes from a raw line (`fold.rs`, `chief-turn`'s `Line::User`).
fn read_fields(kind: &str, msg: &Value) -> Value {
    let blocks: Vec<Value> = msg
        .pointer("/message/content")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .map(|b| {
                    json!([b.get("type"), b.get("id"), b.get("tool_use_id"), b.get("is_error")])
                })
                .collect()
        })
        .unwrap_or_default();
    json!([
        kind,
        msg.get("type"),
        msg.get("isReplay"),
        msg.get("parent_tool_use_id"),
        msg.get("session_id"),
        msg.pointer("/message/id"),
        msg.pointer("/message/model"),
        msg.pointer("/message/usage"),
        blocks
    ])
}

/// The log bytes of real Claude chats (`ACPMUX_BODIES_LOGS`, session folders joined by `:`)
/// with each raw assistant and user line as logged before and after, with what every reader
/// reads of each line and the transcript at each turn's end compared.
#[test]
#[ignore = "reads chat logs named by ACPMUX_BODIES_LOGS"]
fn bodies_perf() {
    use crate::store::EventRecord;
    use crate::transcript::Transcript;
    let Ok(dirs) = std::env::var("ACPMUX_BODIES_LOGS") else { return };
    let size = |r: &EventRecord| serde_json::to_string(r).unwrap().len() + 1;
    for dir in dirs.split(':') {
        let mut files: Vec<_> = std::fs::read_dir(std::path::Path::new(dir).join("events"))
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "ndjson"))
            .collect();
        files.sort();
        let (mut sent, mut kept) = (Transcript::default(), Transcript::default());
        let (mut before, mut after, mut calls, mut turns, mut checks, mut differ, mut fields) =
            (0usize, 0usize, 0usize, 0usize, 0usize, 0usize, 0usize);
        for file in files {
            for line in BufReader::new(std::fs::File::open(file).unwrap()).lines() {
                let Ok(rec) = serde_json::from_str::<EventRecord>(&line.unwrap()) else { continue };
                calls += usize::from(rec.kind == "tool_call");
                turns += usize::from(rec.kind == "turn_result");
                let mut out = rec.clone();
                if rec.dir == "in" {
                    leave_out_bodies(&rec.kind, &mut out.msg);
                }
                fields += usize::from(
                    read_fields(&rec.kind, &rec.msg) != read_fields(&out.kind, &out.msg),
                );
                before += size(&rec);
                after += size(&out);
                sent.apply_event(&serde_json::to_value(&rec).unwrap());
                kept.apply_event(&serde_json::to_value(&out).unwrap());
                if rec.kind == "turn_result" {
                    checks += 1;
                    differ += usize::from(sent.items != kept.items);
                }
            }
        }
        checks += 1;
        differ += usize::from(sent.items != kept.items);
        let mb = |b: usize| b as f64 / 1e6;
        let kb = |b: usize, n: usize| b as f64 / 1e3 / n.max(1) as f64;
        println!(
            "{dir}: {:.1} -> {:.1} MB ({:+.0}%), per tool call {:.1} -> {:.1} KB ({calls}), per \
             turn {:.0} -> {:.0} KB ({turns}); transcript differs at {differ} of {checks} \
             checkpoints, read fields at {fields} records",
            mb(before),
            mb(after),
            100.0 * (after as f64 - before as f64) / before as f64,
            kb(before, calls),
            kb(after, calls),
            kb(before, turns),
            kb(after, turns),
        );
        assert_eq!((differ, fields), (0, 0), "{dir}");
    }
}
