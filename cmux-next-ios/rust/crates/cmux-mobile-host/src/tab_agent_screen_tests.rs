use super::*;

fn turn(who: &str, text: &str) -> AgentTurn {
    AgentTurn { who: who.to_owned(), text: text.to_owned() }
}

fn user(seq: u64, text: &str) -> Value {
    json!({"seq": seq, "dir": "mux", "kind": "user_message", "msg": {"text": text}})
}

fn chunk(seq: u64, text: &str) -> Value {
    json!({"seq": seq, "dir": "in", "kind": "session/update", "msg": {"method": "session/update",
        "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}})
}

fn tool(seq: u64) -> Value {
    json!({"seq": seq, "dir": "in", "kind": "session/update", "msg": {"method": "session/update",
        "params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "ls"}}}})
}

#[test]
fn the_text_keeps_the_newest_three_turns_with_who_spoke() {
    let turns = [turn("You", "one"), turn("Claude", "two"), turn("You", "three"), turn("Claude", "four")];
    let text = agent_screen(&turns).unwrap();
    assert_eq!(text, "Claude\ntwo\n\nYou\nthree\n\nClaude\nfour");
}

#[test]
fn empty_turns_give_no_text() {
    assert_eq!(agent_screen(&[]), None);
    assert_eq!(agent_screen(&[turn("You", "  "), turn("Claude", "\n")]), None);
    // An empty turn is not one of the three.
    let text =
        agent_screen(&[turn("You", "a"), turn("Claude", "b"), turn("You", "c"), turn("Claude", "")]).unwrap();
    assert!(text.starts_with("You\na"), "{text}");
}

#[test]
fn long_lines_wrap_to_eighty_columns_at_a_space() {
    let words = "word ".repeat(60);
    let text = agent_screen(&[turn("Claude", &words)]).unwrap();
    for line in text.lines() {
        assert!(line.chars().count() <= AGENT_SCREEN_COLS, "{line:?}");
    }
    assert!(text.lines().skip(1).all(|l| !l.starts_with(' ') && !l.ends_with(' ')));
    // A word longer than a row is cut hard.
    let rows = wrap(&"x".repeat(200), AGENT_SCREEN_COLS);
    assert_eq!(rows.iter().map(|r| r.chars().count()).collect::<Vec<_>>(), vec![80, 80, 40]);
}

#[test]
fn the_text_holds_at_most_four_kib_on_a_character_boundary() {
    for fill in ["a", "é", "日本", "🦀"] {
        let huge = fill.repeat(20_000);
        let turns = [turn("You", &huge), turn("Claude", &huge), turn("You", &huge)];
        let text = agent_screen(&turns).unwrap();
        assert!(text.len() <= MAX_AGENT_SCREEN_BYTES, "{fill}: {}", text.len());
        // Each of the three turns keeps its name and its share.
        assert_eq!(text.matches("\n\n").count(), 2, "{fill}");
        assert!(text.contains('…'));
        let one = agent_screen(&[turn("Claude", &huge)]).unwrap();
        assert!(one.len() <= MAX_AGENT_SCREEN_BYTES && one.len() > MAX_AGENT_SCREEN_BYTES / 2, "{fill}");
    }
}

#[test]
fn records_make_turns_of_the_persons_messages_and_the_agents_replies() {
    let records = [
        user(1, "fix the build"),
        chunk(2, "Looking"),
        tool(3),
        chunk(4, " at it."),
        user(5, "thanks"),
        chunk(6, "Done."),
        json!({"seq": 7, "dir": "in", "kind": "session/update.replay", "msg": {"method": "session/update",
            "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"text": "old"}}}}}),
    ];
    assert_eq!(
        turns_of(&records, "Codex"),
        vec![
            turn("You", "fix the build"),
            turn("Codex", "Looking at it."),
            turn("You", "thanks"),
            turn("Codex", "Done.")
        ]
    );
}

#[test]
fn the_session_comes_from_the_fields_the_exposure_rule_reads() {
    assert_eq!(agent_session(&json!({"agent_session": "s1"})).as_deref(), Some("s1"));
    assert_eq!(
        agent_session(&json!({"conversation": {"agent_session": {"session": "s2"}}})).as_deref(),
        Some("s2")
    );
    assert_eq!(
        agent_session(&json!({"extra": {"conversation": {"agent_session": {"session": "s3"}}}})).as_deref(),
        Some("s3")
    );
    assert_eq!(agent_session(&json!({"session": "terminal-registry"})), None);
    assert_eq!(agent_name(&json!({"agent": "Claude"})), "Claude");
    assert_eq!(agent_name(&json!({"agent_session": {"session": "s", "harness": "codex"}})), "Codex");
    assert_eq!(agent_name(&json!({"conversation": {"agent_session": {"harness": "claude"}}})), "Claude");
    assert_eq!(agent_name(&json!({})), "Agent");
}

/// `n` agent tabs, `tab-i` showing chat `s-i`.
fn agents(n: usize) -> HashMap<String, (String, String)> {
    (0..n).map(|i| (format!("tab-{i}"), (format!("s-{i}"), "Claude".to_owned()))).collect()
}

/// Appends `line` to chat `session`'s log segment `segment` under `root`.
fn append(root: &Path, session: &str, segment: &str, line: &str) {
    let events = root.join(session).join("events");
    std::fs::create_dir_all(&events).unwrap();
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(events.join(segment)).unwrap();
    std::io::Write::write_all(&mut file, line.as_bytes()).unwrap();
}

fn ids(reads: &[AgentRead]) -> Vec<&str> {
    let mut ids: Vec<&str> = reads.iter().map(|r| r.tab_id.as_str()).collect();
    ids.sort_unstable();
    ids
}

#[test]
fn the_segment_after_keeps_its_width() {
    assert_eq!(next_segment(Path::new("/e/000006.ndjson")), Some(PathBuf::from("/e/000007.ndjson")));
    assert_eq!(next_segment(Path::new("/e/999999.ndjson")), Some(PathBuf::from("/e/1000000.ndjson")));
    assert_eq!(next_segment(Path::new("/e/cold.ndjson")), None);
}

/// Steady state is constant cost: N idle agent tabs whose logs are on this
/// disk ask for no read on any tick, looked at on time or named by an event;
/// only the tab whose log moved is read.
#[test]
fn idle_agent_tabs_cause_no_read_on_a_tick() {
    const N: usize = 500;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    for i in 0..N {
        append(root, &format!("s-{i}"), "000001.ndjson", "{\"seq\":1}\n");
    }
    let reads = AgentReads::default();
    let mut schedule = AgentSchedule::default();
    schedule.listed(agents(N), &reads);
    let start = Instant::now();
    let first = schedule.due(start, Some(root), &reads);
    assert_eq!(first.len(), N, "each new tab is read once");
    for read in first {
        assert!(matches!(read.stamp, Some(LogStamp::Segment { .. })));
        reads.record(&read.tab_id, 1, read.stamp);
    }
    // Four look intervals of 100 ms feeder ticks, every tab named by an event halfway.
    let tick = Duration::from_millis(100);
    let ticks = (AGENT_INTERVAL * 4).as_millis() / tick.as_millis();
    for at in 1..=ticks {
        if at == ticks / 2 {
            for i in 0..N {
                schedule.named(&format!("tab-{i}"));
            }
        }
        let due = schedule.due(start + tick * at as u32, Some(root), &reads);
        assert!(due.is_empty(), "tick {at}: {:?}", ids(&due));
    }

    // One chat goes on: only its tab is read, at its next look.
    append(root, "s-7", "000001.ndjson", "{\"seq\":2}\n");
    let later = start + tick * ticks as u32 + AGENT_INTERVAL;
    let due = schedule.due(later, Some(root), &reads);
    assert_eq!(ids(&due), ["tab-7"]);
    reads.record("tab-7", 2, due[0].stamp.clone());
    // A new segment is seen too (the folder's listing changes).
    append(root, "s-9", "000002.ndjson", "{\"seq\":2}\n");
    let due = schedule.due(later + AGENT_INTERVAL, Some(root), &reads);
    assert_eq!(ids(&due), ["tab-9"]);
    assert!(
        matches!(&due[0].stamp, Some(LogStamp::Segment { path, .. }) if path.ends_with("000002.ndjson")),
        "{:?}",
        due[0].stamp
    );
    reads.record("tab-9", 2, due[0].stamp.clone());
    assert!(schedule.due(later + AGENT_INTERVAL * 2, Some(root), &reads).is_empty());
}

/// A captured tab whose log is not on this disk is asked again only when an
/// event names it or every [`AGENT_UNSTAMPED_INTERVAL`].
#[test]
fn a_tab_with_no_log_here_is_asked_rarely() {
    let reads = AgentReads::default();
    let mut schedule = AgentSchedule::default();
    schedule.listed(agents(3), &reads);
    let start = Instant::now();
    let first = schedule.due(start, None, &reads);
    assert_eq!(first.len(), 3);
    for read in &first {
        assert_eq!(read.stamp, None);
        reads.record(&read.tab_id, 1, None);
    }
    let mut at = AGENT_INTERVAL;
    while at < AGENT_UNSTAMPED_INTERVAL {
        assert!(schedule.due(start + at, None, &reads).is_empty(), "{at:?}");
        at += AGENT_INTERVAL;
    }
    schedule.named("tab-1");
    assert_eq!(ids(&schedule.due(start + at - AGENT_INTERVAL / 2, None, &reads)), ["tab-1"]);
    assert_eq!(ids(&schedule.due(start + at + AGENT_INTERVAL, None, &reads)), ["tab-0", "tab-2"]);
    // A tab dropped from the list forgets its capture.
    schedule.listed(agents(1), &reads);
    assert!(reads.captured("tab-0") && !reads.captured("tab-1"));
}

/// Two tabs on one chat each keep their own capture.
#[test]
fn captures_are_kept_per_tab() {
    let reads = AgentReads::default();
    reads.record("tab-a", 4, None);
    assert!(reads.fresh("tab-a", 4));
    assert!(!reads.fresh("tab-b", 4), "a second tab on the chat is read for itself");
}

/// At most [`MAX_CONCURRENT_READS`] reads run at once, and the reads end with
/// the feeder's task set: dropping it aborts them, in flight or waiting.
#[tokio::test]
async fn reads_are_capped_and_end_with_the_feeder() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    // An acpmux that takes connections and never answers.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target =
        AcpmuxTarget::Fixed { url: format!("ws://{}/", listener.local_addr().unwrap()), token: None };
    let accepted = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&accepted);
    let server = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = listener.accept().await {
            counted.fetch_add(1, Ordering::SeqCst);
            held.push(stream);
        }
    });
    let tabs = Arc::new(Tabs::new("t"));
    let reads = Arc::new(AgentReads::default());
    let mut tasks = JoinSet::new();
    for (tab_id, (session, agent)) in agents(10) {
        let read = AgentRead { tab_id, session, agent, stamp: None };
        reads.spawn(&mut tasks, &tabs, target.clone(), read.clone());
        // A second read of a tab in flight is not started.
        reads.spawn(&mut tasks, &tabs, target.clone(), read);
    }
    assert_eq!(tasks.len(), 10);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(accepted.load(Ordering::SeqCst), MAX_CONCURRENT_READS);
    assert_eq!(reads.permits.available_permits(), 0);

    drop(tasks);
    for _ in 0..100 {
        if reads.inflight.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(reads.inflight.lock().unwrap().is_empty(), "the reads outlived the feeder");
    assert_eq!(reads.permits.available_permits(), MAX_CONCURRENT_READS);
    assert_eq!(accepted.load(Ordering::SeqCst), MAX_CONCURRENT_READS, "no waiting read started");
    server.abort();
}
