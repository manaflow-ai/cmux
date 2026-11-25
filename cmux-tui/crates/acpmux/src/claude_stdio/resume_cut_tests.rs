//! `resume_cut.rs`: the transcript a move cut at a tool boundary, and the turn a process resumes
//! by itself.

use super::resume_cut::prepare;
use super::*;

const ASK: &str =
    r#"{"type":"user","message":{"role":"user","content":"run three steps"},"uuid":"u1"}"#;
const CALL: &str = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo one"}}]},"uuid":"a1"}"#;
const RESULT: &str = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"one"}]},"uuid":"u2"}"#;
const SNAPSHOT: &str =
    r#"{"type":"attachment","attachment":{"type":"prompt_snapshot"},"uuid":"s1"}"#;
const STOPPED: &str = r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"u3"}"#;
const LAST: &str = r#"{"type":"last-prompt","lastPrompt":"run three steps"}"#;
const SAID: &str = r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]},"uuid":"a2"}"#;

fn transcript(lines: &[&str]) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s.jsonl");
    let mut text = lines.join("\n");
    text.push('\n');
    std::fs::write(&path, text).unwrap();
    (dir, path)
}

fn lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path).unwrap().lines().map(str::to_owned).collect()
}

/// The transcript the measured Stop left (Claude Code 2.1.330): only the Stop's line goes, and
/// what follows it stays.
#[test]
fn the_stops_line_goes_and_the_transcript_ends_at_the_tool_result() {
    let (_dir, path) = transcript(&[ASK, CALL, RESULT, SNAPSHOT, STOPPED, LAST]);
    assert!(prepare(&path).unwrap());
    assert_eq!(lines(&path), [ASK, CALL, RESULT, SNAPSHOT, LAST]);
    // Again (a start tried twice): the same answer, the same file.
    assert!(prepare(&path).unwrap());
    assert_eq!(lines(&path), [ASK, CALL, RESULT, SNAPSHOT, LAST]);
}

#[test]
fn a_transcript_that_ends_at_a_tool_result_needs_no_change() {
    let (_dir, path) = transcript(&[ASK, CALL, RESULT]);
    assert!(prepare(&path).unwrap());
    assert_eq!(lines(&path), [ASK, CALL, RESULT]);
}

/// Not at a tool boundary: the continuation's text is written, and the file is as it was.
#[test]
fn any_other_end_keeps_the_text_and_the_file() {
    for end in [
        vec![ASK, CALL, RESULT, SAID, STOPPED],
        vec![ASK, CALL, STOPPED],
        vec![ASK, STOPPED],
        vec![ASK, CALL, RESULT, SAID],
        vec![SNAPSHOT, LAST],
    ] {
        let (_dir, path) = transcript(&end);
        assert!(!prepare(&path).unwrap(), "{end:?}");
        assert_eq!(lines(&path), end);
    }
    assert!(prepare(Path::new("/nonexistent/acpmux-resume-cut.jsonl")).is_err());
}

/// A tool result longer than the first window read is still found.
#[test]
fn a_long_tool_result_is_read_back_to() {
    let long = RESULT.replace("\"one\"", &format!("\"{}\"", "x".repeat(600 * 1024)));
    let (_dir, path) = transcript(&[ASK, CALL, &long, STOPPED, LAST]);
    assert!(prepare(&path).unwrap());
    assert_eq!(lines(&path), [ASK, CALL, long.as_str(), LAST]);
}

/// The process resumes the turn by itself: the hub's prompt for it writes nothing and is
/// answered by the turn's result; output is held until that prompt comes.
#[tokio::test]
async fn the_resumed_turn_takes_the_carried_prompt_and_writes_nothing() {
    let tr = Translator::new("s".into(), "default", "default", "default");
    assert!(tr.holding().is_none());
    tr.owe_resumed();
    assert!(tr.holding().is_some(), "output is held until the turn's prompt comes");
    let prompt = Message::request(
        7,
        method::SESSION_PROMPT,
        json!({"sessionId": "c", "prompt": [], "_meta": {"carried": true}}),
    );
    match tr.outbound(&prompt).await {
        Outbound::Lines(lines) => assert!(lines.is_empty(), "{lines:?}"),
        _ => panic!("the carried prompt is answered by the turn's result, not at once"),
    }
    assert!(tr.holding().is_none());
    let pending = tr.pending.lock().await;
    assert_eq!(pending.len(), 1);
    assert!(pending.values().all(|p| matches!(p, Pending::Prompt)));
}
