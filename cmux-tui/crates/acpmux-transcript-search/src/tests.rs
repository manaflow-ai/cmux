use std::io::Write as _;
use std::path::Path;

use serde_json::json;

use crate::parse::{self, Harness, LineState, Role};
use crate::{Index, Query, Roots, Source};

fn claude_user(text: &str, at: &str) -> String {
    json!({"type": "user", "timestamp": at, "message": {"role": "user", "content": text}})
        .to_string()
}

fn claude_assistant(text: &str, at: &str) -> String {
    json!({"type": "assistant", "timestamp": at,
        "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
    .to_string()
}

fn claude_tool(command: &str, output: &str, at: &str) -> Vec<String> {
    vec![
        json!({"type": "assistant", "timestamp": at, "message": {"content": [
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": command}}]}})
        .to_string(),
        json!({"type": "user", "timestamp": at, "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": output}]}})
        .to_string(),
    ]
}

fn append(path: &Path, lines: &[String]) {
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    for l in lines {
        writeln!(f, "{l}").unwrap();
    }
}

fn source(path: &Path, session: &str) -> Source {
    Source {
        path: path.to_owned(),
        harness: Harness::Claude,
        session: session.into(),
        subagent: false,
    }
}

#[test]
fn claude_lines_give_prompts_replies_and_tools_unescaped() {
    let mut state = LineState::default();
    let line = claude_user("line one\nline \"two\"", "2026-11-18T09:00:00.000Z");
    let got = parse::line(Harness::Claude, line.as_bytes(), &mut state);
    assert_eq!(got.docs.len(), 1);
    assert_eq!(got.docs[0].role, Role::User);
    assert_eq!(got.docs[0].text, "line one\nline \"two\"");
    assert_eq!(got.at_ms, Some(1_794_992_400_000));
    assert_eq!(state.turn, 1);

    let tool = claude_tool("rg -n 'x'", "a\nb", "2026-11-18T09:00:01Z");
    let call = parse::line(Harness::Claude, tool[0].as_bytes(), &mut state);
    assert_eq!(call.docs[0].role, Role::Tool);
    assert_eq!(call.docs[0].text, "Bash\nrg -n 'x'");
    let result = parse::line(Harness::Claude, tool[1].as_bytes(), &mut state);
    assert_eq!(result.docs[0].text, "a\nb");
    // A tool result is not a prompt.
    assert_eq!(state.turn, 1);

    let skipped = json!({"type": "api-request-blob", "message": {"content": "type\":\"user\""}});
    assert!(
        parse::line(Harness::Claude, skipped.to_string().as_bytes(), &mut state).docs.is_empty()
    );
    let meta = json!({"type": "user", "isMeta": true, "message": {"content": "skill text"}});
    assert!(parse::line(Harness::Claude, meta.to_string().as_bytes(), &mut state).docs.is_empty());
    let summary = json!({"type": "user", "isCompactSummary": true,
        "message": {"content": "This session is being continued: the four agent pages"}});
    let got = parse::line(Harness::Claude, summary.to_string().as_bytes(), &mut state);
    assert_eq!(got.docs.len(), 1);
    assert_eq!(state.turn, 1, "a compaction summary is not a new turn");
    assert!(
        parse::line(Harness::Claude, b"not json \"type\":\"user\"", &mut state).docs.is_empty()
    );
}

#[test]
fn codex_lines_give_prompts_replies_tools_and_compaction_summaries() {
    let mut state = LineState::default();
    let at = "2026-11-18T09:00:00.000Z";
    let lines = [
        json!({"timestamp": at, "type": "session_meta", "payload": {"id": "x"}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "<environment_context>cwd</environment_context>"}]}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "message", "role": "developer",
            "content": [{"type": "input_text", "text": "rules"}]}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "find the bug"}]}}),
        json!({"timestamp": at, "type": "event_msg", "payload": {"type": "user_message", "message": "find the bug"}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "function_call", "name": "shell",
            "arguments": "{\"command\":[\"bash\",\"-lc\",\"ls\\n-la\"]}"}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "function_call_output",
            "output": "{\"output\":\"total 0\\n\",\"metadata\":{}}"}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "custom_tool_call", "name": "exec",
            "input": "tools.exec_command({cmd: \"cat x\"})"}}),
        json!({"timestamp": at, "type": "response_item", "payload": {"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "Found it."}]}}),
        json!({"timestamp": at, "type": "compacted", "payload": {"message": "Summary of earlier work", "replacement_history": []}}),
    ];
    let docs: Vec<(Role, String)> = lines
        .iter()
        .flat_map(|l| parse::line(Harness::Codex, l.to_string().as_bytes(), &mut state).docs)
        .map(|d| (d.role, d.text))
        .collect();
    assert_eq!(
        docs,
        vec![
            (Role::User, "find the bug".into()),
            (Role::Tool, "shell\nbash\n-lc\nls\n-la".into()),
            (Role::Tool, "total 0\n".into()),
            (Role::Tool, "exec\ntools.exec_command({cmd: \"cat x\"})".into()),
            (Role::Assistant, "Found it.".into()),
            (Role::Assistant, "Summary of earlier work".into()),
        ]
    );
    assert_eq!(state.turn, 1);
}

#[test]
fn rfc3339_times_parse_with_fractions_and_offsets() {
    assert_eq!(parse::parse_rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(parse::parse_rfc3339_ms("1970-01-01T00:00:01.5Z"), Some(1500));
    assert_eq!(parse::parse_rfc3339_ms("1970-01-01T01:00:00+01:00"), Some(0));
    assert_eq!(parse::parse_rfc3339_ms("2026-11-18T09:00:00.123456Z"), Some(1_794_992_400_123));
    assert_eq!(parse::parse_rfc3339_ms("yesterday"), None);
}

#[test]
fn search_finds_a_phrase_newest_first_with_context_and_real_newlines() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("s1.jsonl");
    let mut lines = vec![
        claude_user("Please write the four agent pages.", "2026-11-18T09:00:00Z"),
        claude_assistant(
            "Plan:\nfirst the FOUR AGENT PAGES, then the rest.",
            "2026-11-18T09:00:05Z",
        ),
    ];
    lines.extend(claude_tool("ls pages", "four agent pages.md", "2026-11-18T09:00:06Z"));
    append(&path, &lines);
    let index = Index::in_memory().unwrap();
    let src = source(&path, "s1");
    let (hits, done) = crate::search(&index, &[src], &Query::new("four agent pages")).unwrap();
    assert_eq!(done.caught_up.docs, 4);
    assert_eq!(hits.len(), 3);
    assert_eq!(hits[0].role, Role::Tool);
    assert_eq!(hits[1].role, Role::Assistant);
    assert_eq!(hits[1].snippet, "Plan:\nfirst the FOUR AGENT PAGES, then the rest.");
    assert_eq!(&hits[1].snippet[hits[1].match_start..][..hits[1].match_len], "FOUR AGENT PAGES");
    assert_eq!(hits[1].turn, 1);
    assert_eq!(hits[1].line, 2);
    assert_eq!(hits[2].role, Role::User);

    let mut q = Query::new("four agent pages");
    q.role = Some(Role::Assistant);
    assert_eq!(index.search(&q).unwrap().len(), 1);
    q.role = None;
    q.limit = 1;
    assert_eq!(index.search(&q).unwrap()[0].role, Role::Tool);
    q.limit = 20;
    q.since_ms = parse::parse_rfc3339_ms("2026-11-18T09:00:04Z");
    assert_eq!(index.search(&q).unwrap().len(), 2);
    q.since_ms = None;
    q.context = 5;
    let short = index.search(&q).unwrap();
    assert_eq!(short[1].snippet, " the FOUR AGENT PAGES, the");
    assert!(short[1].cut_before && short[1].cut_after);
    assert!(index.search(&Query::new("absent words here")).unwrap().is_empty());
    assert!(index.search(&Query::new("   ")).unwrap().is_empty());
}

#[test]
fn a_session_filter_reads_only_that_sessions_transcripts() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a.jsonl"), dir.path().join("b.jsonl"));
    append(&a, &[claude_user("shared words in a", "2026-11-18T09:00:00Z")]);
    append(&b, &[claude_user("shared words in b", "2026-11-18T10:00:00Z")]);
    let index = Index::in_memory().unwrap();
    let sources = [source(&a, "a"), source(&b, "b")];
    let (all, _) = crate::search(&index, &sources, &Query::new("shared words")).unwrap();
    assert_eq!(all.iter().map(|h| h.session.as_str()).collect::<Vec<_>>(), ["b", "a"]);
    let mut q = Query::new("shared words");
    q.sessions = Some(vec!["a".into()]);
    let one = index.search(&q).unwrap();
    assert_eq!(one.len(), 1);
    assert_eq!(one[0].session, "a");
}

#[test]
fn a_wildcard_character_in_the_text_matches_only_itself() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("w.jsonl");
    append(
        &path,
        &[
            claude_user("call session_search now", "2026-11-18T09:00:00Z"),
            claude_user("call sessionXsearch now", "2026-11-18T09:00:01Z"),
            claude_user("100% done", "2026-11-18T09:00:02Z"),
            claude_user("100 is done", "2026-11-18T09:00:03Z"),
        ],
    );
    let index = Index::in_memory().unwrap();
    index.catch_up(&source(&path, "w")).unwrap();
    let hits = index.search(&Query::new("session_search")).unwrap();
    assert_eq!(hits.len(), 1);
    assert!(hits[0].snippet.contains("session_search"));
    assert_eq!(index.search(&Query::new("100% d")).unwrap().len(), 1);
}

#[test]
fn catch_up_reads_only_what_was_appended_and_never_a_partial_line() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("grow.jsonl");
    append(&path, &[claude_user("first prompt alpha", "2026-11-18T09:00:00Z")]);
    let index = Index::in_memory().unwrap();
    let src = source(&path, "g");
    let first = index.catch_up(&src).unwrap();
    assert_eq!(first.docs, 1);
    assert!(!first.reread);
    assert_eq!(index.catch_up(&src).unwrap(), crate::CatchUp::default());

    // A line still being written is not read until it ends.
    let next = claude_assistant("second reply beta", "2026-11-18T09:00:01Z");
    let (head, tail) = next.split_at(next.len() / 2);
    let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    write!(f, "{head}").unwrap();
    assert_eq!(index.catch_up(&src).unwrap().docs, 0);
    writeln!(f, "{tail}").unwrap();
    let step = index.catch_up(&src).unwrap();
    assert_eq!(step.docs, 1);
    assert_eq!(step.bytes, next.len() as u64 + 1);
    assert_eq!(index.search(&Query::new("second reply beta")).unwrap()[0].line, 2);
    assert_eq!(index.stats().unwrap(), (1, 2));
}

#[test]
fn a_rewritten_or_shorter_transcript_is_read_again_from_the_start() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("re.jsonl");
    append(
        &path,
        &[
            claude_user("old words one", "2026-11-18T09:00:00Z"),
            claude_user("old words two", "2026-11-18T09:00:01Z"),
        ],
    );
    let index = Index::in_memory().unwrap();
    let src = source(&path, "r");
    index.catch_up(&src).unwrap();
    // Rewritten in place, the same length or shorter: what was there is gone.
    std::fs::write(&path, format!("{}\n", claude_user("new words", "2026-11-18T09:00:02Z")))
        .unwrap();
    let again = index.catch_up(&src).unwrap();
    assert!(again.reread);
    assert!(index.search(&Query::new("old words")).unwrap().is_empty());
    assert_eq!(index.search(&Query::new("new words")).unwrap().len(), 1);
    assert_eq!(index.stats().unwrap(), (1, 1));
}

#[test]
fn an_index_reopened_from_disk_resumes_where_it_stopped() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("t.jsonl");
    let db = dir.path().join("idx/index.sqlite");
    append(&path, &[claude_user("before restart", "2026-11-18T09:00:00Z")]);
    let src = source(&path, "t");
    Index::open(&db).unwrap().catch_up(&src).unwrap();
    append(&path, &[claude_user("after restart", "2026-11-18T09:00:01Z")]);
    let index = Index::open(&db).unwrap();
    assert_eq!(index.catch_up(&src).unwrap().docs, 1);
    assert_eq!(index.stats().unwrap(), (1, 2));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&db).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn roots_find_claude_sessions_subagents_and_codex_rollouts() {
    let home = tempfile::tempdir().unwrap();
    let project = home.path().join(".claude/projects/-Users-me-src");
    std::fs::create_dir_all(project.join("sess-1/subagents")).unwrap();
    std::fs::write(project.join("sess-1.jsonl"), "").unwrap();
    std::fs::write(project.join("sess-1/subagents/agent-a1.jsonl"), "").unwrap();
    std::fs::write(project.join("sess-2.jsonl"), "").unwrap();
    let id = "01a18a62-5096-7920-a488-5f211f95fd9e";
    let day = home.path().join(".codex/sessions/2026/10/29");
    std::fs::create_dir_all(&day).unwrap();
    std::fs::write(day.join(format!("rollout-2026-10-29T18-17-41-{id}.jsonl")), "").unwrap();
    let roots = Roots::default_for(home.path(), |_| None);

    let mut all: Vec<(String, bool, Harness)> =
        roots.all().into_iter().map(|s| (s.session, s.subagent, s.harness)).collect();
    all.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    assert_eq!(
        all,
        vec![
            (id.to_owned(), false, Harness::Codex),
            ("sess-1".into(), false, Harness::Claude),
            ("sess-1".into(), true, Harness::Claude),
            ("sess-2".into(), false, Harness::Claude),
        ]
    );
    assert_eq!(roots.session("sess-1").len(), 2);
    assert_eq!(roots.session(id).len(), 1);
    assert!(roots.session("../x").is_empty());
    assert!(roots.session("missing").is_empty());
}
