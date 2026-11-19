use std::io::Write as _;
use std::path::Path;

use serde_json::json;

use super::*;
use crate::{Index, Source};

fn user(text: &str) -> String {
    json!({"type": "user", "timestamp": "2026-11-18T09:00:00Z", "message": {"content": text}})
        .to_string()
}

fn assistant(text: &str) -> String {
    json!({"type": "assistant", "timestamp": "2026-11-18T09:00:01Z",
        "message": {"content": [{"type": "text", "text": text}]}})
    .to_string()
}

fn tool(command: &str, output: &str) -> [String; 2] {
    [
        json!({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": command}}]}})
        .to_string(),
        json!({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": output}]}})
        .to_string(),
    ]
}

fn write(path: &Path, lines: &[String]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut f = std::fs::File::create(path).unwrap();
    for l in lines {
        writeln!(f, "{l}").unwrap();
    }
}

/// An index at `dir/index.sqlite` holding `sources`, and a reader of it.
fn indexed(dir: &Path, sources: &[Source]) -> (Index, Reader) {
    let at = dir.join("index.sqlite");
    let index = Index::open(&at).unwrap();
    for s in sources {
        index.catch_up(s).unwrap();
    }
    (index, Reader::open(&at).unwrap())
}

fn source(path: &Path, subagent: bool) -> Source {
    Source { path: path.to_owned(), harness: Harness::Claude, session: "s1".into(), subagent }
}

/// Lines 1-6: prompt, reply, tool call, tool output, a bookkeeping line, prompt, reply.
fn chat(dir: &Path) -> PathBuf {
    let path = dir.join("p/s1.jsonl");
    let [call, output] = tool("rg -n merge_hold", "src/a.rs:1: merge_hold");
    write(
        &path,
        &[
            user("Find where merge_hold is set.\nThen fix it."),
            assistant("Looking for \"merge_hold\" now."),
            call,
            output,
            json!({"type": "queue-operation", "operation": "enqueue"}).to_string(),
            user("Now the four agent pages."),
            assistant("Done: the four agent pages."),
        ],
    );
    path
}

fn texts(read: &Read) -> Vec<(u64, Role, &str, bool)> {
    read.messages.iter().map(|m| (m.line, m.role, m.text.as_str(), m.anchor)).collect()
}

#[test]
fn a_line_reads_its_message_whole_and_unescaped_with_the_ones_next_to_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = chat(dir.path());
    let (_index, reader) = indexed(dir.path(), &[source(&path, false)]);

    let mut q = ReadQuery::new("s1", At::Line(2));
    let alone = reader.read(&q).unwrap();
    assert_eq!(texts(&alone), vec![(2, Role::Assistant, "Looking for \"merge_hold\" now.", true)]);
    assert!(alone.more_before && alone.more_after && !alone.truncated);
    assert_eq!(alone.file.lines, 7);
    assert_eq!(alone.file.turns, 2);
    assert_eq!(alone.messages[0].turn, 1);

    q.before = 1;
    q.after = 2;
    let around = reader.read(&q).unwrap();
    assert_eq!(
        texts(&around),
        vec![
            (1, Role::User, "Find where merge_hold is set.\nThen fix it.", false),
            (2, Role::Assistant, "Looking for \"merge_hold\" now.", true),
            (3, Role::Tool, "Bash\nrg -n merge_hold", false),
            (4, Role::Tool, "src/a.rs:1: merge_hold", false),
        ]
    );
    assert!(!around.more_before);

    // Without tools, the messages next to it are the prompt and the reply around the calls.
    q.tools = false;
    q.after = 1;
    let no_tools = reader.read(&q).unwrap();
    assert_eq!(no_tools.messages.iter().map(|m| m.line).collect::<Vec<_>>(), vec![1, 2, 6]);
}

#[test]
fn a_turn_reads_every_message_of_it_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let path = chat(dir.path());
    let (_index, reader) = indexed(dir.path(), &[source(&path, false)]);

    let first = reader.read(&ReadQuery::new("s1", At::Turn(1))).unwrap();
    assert_eq!(first.messages.iter().map(|m| m.line).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
    assert!(first.messages.iter().all(|m| m.anchor));
    assert!(!first.more_before && first.more_after);

    let mut q = ReadQuery::new("s1", At::Turn(2));
    q.before = 1;
    q.tools = false;
    let both = reader.read(&q).unwrap();
    assert_eq!(
        both.messages.iter().map(|m| (m.line, m.anchor)).collect::<Vec<_>>(),
        vec![(1, false), (2, false), (6, true), (7, true)]
    );
    assert!(!both.more_after);
}

#[test]
fn a_read_stays_within_its_byte_budget_and_says_what_it_left_out() {
    let dir = tempfile::tempdir().unwrap();
    let path = chat(dir.path());
    let (_index, reader) = indexed(dir.path(), &[source(&path, false)]);

    let mut q = ReadQuery::new("s1", At::Line(1));
    q.max_bytes = 10;
    q.after = 5;
    let cut = reader.read(&q).unwrap();
    assert_eq!(texts(&cut), vec![(1, Role::User, "Find where", true)]);
    assert!(cut.messages[0].cut && cut.truncated);

    // A neighbour goes in whole or not at all.
    q.max_bytes = "Find where merge_hold is set.\nThen fix it.".len() + 5;
    let whole = reader.read(&q).unwrap();
    assert_eq!(whole.messages.len(), 1);
    assert!(!whole.messages[0].cut && whole.truncated);
}

#[test]
fn a_place_the_index_does_not_hold_is_not_found() {
    let dir = tempfile::tempdir().unwrap();
    let path = chat(dir.path());
    let (_index, reader) = indexed(dir.path(), &[source(&path, false)]);
    let missing = |q: ReadQuery| match reader.read(&q) {
        Err(ReadError::NotFound(m)) => m,
        other => panic!("{other:?}"),
    };
    assert!(missing(ReadQuery::new("nope", At::Line(1))).contains("no transcript of session nope"));
    assert!(missing(ReadQuery::new("s1", At::Line(99))).contains("past the 7 lines"));
    assert!(missing(ReadQuery::new("s1", At::Line(5))).contains("next one is at line 6"));
    assert!(missing(ReadQuery::new("s1", At::Turn(3))).contains("past the 2 turns"));
    let mut sub = ReadQuery::new("s1", At::Line(1));
    sub.subagent = Some("agent-x".into());
    assert!(missing(sub).contains("no subagent transcript \"agent-x\""));
}

#[test]
fn a_subagent_transcript_is_read_by_its_name_never_a_path() {
    let dir = tempfile::tempdir().unwrap();
    let path = chat(dir.path());
    let sub = dir.path().join("p/s1/subagents/agent-a1b2.jsonl");
    write(&sub, &[user("subagent task"), assistant("subagent answer")]);
    let (_index, reader) = indexed(dir.path(), &[source(&path, false), source(&sub, true)]);

    let own = reader.read(&ReadQuery::new("s1", At::Line(1))).unwrap();
    assert!(!own.file.subagent);
    assert_eq!(own.files.len(), 2);

    let mut q = ReadQuery::new("s1", At::Line(2));
    for name in ["agent-a1b2", "agent-a1b2.jsonl"] {
        q.subagent = Some(name.into());
        let read = reader.read(&q).unwrap();
        assert!(read.file.subagent);
        assert_eq!(texts(&read), vec![(2, Role::Assistant, "subagent answer", true)]);
    }
    q.subagent = Some(sub.display().to_string());
    assert!(matches!(reader.read(&q), Err(ReadError::NotFound(_))));
}

#[test]
fn a_line_deep_in_a_long_transcript_is_found_by_a_binary_search() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("p/s1.jsonl");
    let mut lines = Vec::new();
    for i in 0..3000 {
        lines.push(user(&format!("prompt {i}")));
        lines.push(json!({"type": "progress"}).to_string());
        let [call, output] = tool(&format!("echo {i}"), &format!("{i}"));
        lines.push(call);
        lines.push(output);
        lines.push(assistant(&format!("reply {i}")));
    }
    write(&path, &lines);
    let (_index, reader) = indexed(dir.path(), &[source(&path, false)]);

    // Prompt 2345 is at line 2345 * 5 + 1, in turn 2346.
    let mut q = ReadQuery::new("s1", At::Line(2345 * 5 + 1));
    q.after = 3;
    let read = reader.read(&q).unwrap();
    assert_eq!(
        read.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
        vec!["prompt 2345", "Bash\necho 2345", "2345", "reply 2345"]
    );
    assert!(read.messages.iter().all(|m| m.turn == 2346));
    let turn = reader.read(&ReadQuery::new("s1", At::Turn(3000))).unwrap();
    assert_eq!(turn.messages.first().map(|m| m.text.as_str()), Some("prompt 2999"));
    assert_eq!(turn.messages.len(), 4);
    assert!(!turn.more_after);
}
