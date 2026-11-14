#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "fault injection and test assertions"
)]
use super::*;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

const SEED: &str = include_str!("../../../acpmux-book/src/translate/fixtures/seed-turn.ndjson");

fn corpus(turns: u64) -> Vec<u8> {
    let mut bytes = Vec::new();
    for turn in 0..turns {
        for line in SEED.lines() {
            let mut value: serde_json::Value = serde_json::from_str(line).unwrap();
            let seq = value["seq"].as_u64().unwrap() + turn * 9;
            value["seq"] = seq.into();
            let line = serde_json::to_string(&value)
                .unwrap()
                .replace("\"t1\"", &format!("\"t{turn}\""))
                .replace("\"p1\"", &format!("\"p{turn}\""));
            bytes.extend_from_slice(line.as_bytes());
            bytes.push(b'\n');
        }
    }
    bytes
}

fn config_at(book: &Path) -> ChatConfig {
    let raw = book.join("source.ndjson");
    ChatConfig::new("chat", book, Harness::V1).with_source_factory(Arc::new(move || {
        source::FileSource::open(&raw).map(|raw| Box::new(raw) as Box<dyn source::RawSource>)
    }))
}
fn fixture(book: &Path, turns: u64) -> ChatConfig {
    fs::create_dir_all(book).unwrap();
    fs::write(book.join("source.ndjson"), corpus(turns)).unwrap();
    config_at(book)
}
fn catch_up(config: ChatConfig) {
    let mut state = open_state(config).unwrap();
    while !read_source(&mut state).unwrap() {}
    checkpoint(&mut state).unwrap();
}
fn rows(book: &Path) -> Vec<(u64, Vec<u8>)> {
    let (mut log, _) = Log::open(book, Options::default()).unwrap();
    let mut cursor = 0;
    let mut result = Vec::new();
    loop {
        let batch = log.since(cursor, 256 * 1024).unwrap();
        let mut bytes = Vec::new();
        let mut spans = Vec::new();
        log.fill(&batch.rows, &mut bytes, &mut spans).unwrap();
        for (row, span) in batch.rows.iter().zip(spans) {
            result.push((row.seq, bytes[span].to_vec()));
        }
        cursor = batch.cursor;
        if !batch.more {
            break;
        }
    }
    result
}
fn wait_health(handle: &ChatHandle, expected: crate::life::Health) {
    let mut health = handle.health.clone();
    tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap().block_on(async {
        tokio::time::timeout(Duration::from_secs(12), async {
            loop {
                if *health.borrow_and_update() == expected {
                    break;
                }
                health.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
    });
}
fn rebuild(config: ChatConfig) {
    let (_tx, rx) = sync_channel(256);
    let queued = Arc::new(Mutex::new(0));
    let mut subs = stream::Subscribers::default();
    let state = rebuild_from_raw(config, &rx, &queued, &AtomicBool::new(false), &mut subs)
        .unwrap()
        .unwrap();
    drop(state);
}

#[test]
fn actor_books_real_rows_and_publishes_running() {
    let home = tempfile::tempdir().unwrap();
    let actor = ChatActor::spawn(fixture(home.path(), 1));
    wait_health(&actor.handle, crate::life::Health::Running);
    actor.join();
    assert!(!rows(home.path()).is_empty());
}

#[test]
fn hidden_settle_discards_every_other_body_field() {
    let home = tempfile::tempdir().unwrap();
    let mut state = open_state(fixture(home.path(), 0)).unwrap();
    let row = OwnedRow {
        id: 1,
        rev: 1,
        kind: RowKind::Text,
        turn: None,
        group: None,
        at: 0,
        open: false,
        bytes: 0,
        lines: 0,
        fields: BTreeMap::from([
            ("hidden".into(), "true".into()),
            ("text".into(), "\"secret\"".into()),
        ]),
    };
    settle_or_open(&mut state, row, RawRange::NONE).unwrap();
    drop(state);
    let result = rows(home.path());
    let value: serde_json::Value = serde_json::from_slice(&result[0].1).unwrap();
    assert_eq!(value["body"], serde_json::json!({"hidden": true}));
}

#[test]
fn no_op_lines_do_not_checkpoint_and_turn_end_does() {
    let home = tempfile::tempdir().unwrap();
    let config = fixture(home.path(), 1);
    let mut state = open_state(config).unwrap();
    let mut place = 0;
    for (index, line) in SEED.split_inclusive('\n').enumerate() {
        let end = place + line.len() as u64;
        let before = fs::read(home.path().join("checkpoint")).ok();
        apply_line(&mut state, line.trim_end().as_bytes(), place, end, end - place).unwrap();
        let after = fs::read(home.path().join("checkpoint")).ok();
        if index == 4 {
            assert_eq!(before, after, "usage-only line writes no checkpoint");
        }
        if index == 8 {
            assert_ne!(before, after, "turn end checkpoints");
        }
        place = end;
    }
}

#[test]
fn rebuild_preserves_colocated_raw_and_edition_without_old_directories() {
    let home = tempfile::tempdir().unwrap();
    let book = home.path().join("chat.1");
    let config = fixture(&book, 2);
    catch_up(config.clone());
    let expected = rows(&book);
    let edition = log::CheckpointHead::read(&book).unwrap().unwrap().edition;
    fs::write(book.join("folds.idx"), []).unwrap();
    rebuild(config.clone());
    assert_eq!(rows(&book), expected);
    assert_eq!(log::CheckpointHead::read(&book).unwrap().unwrap().edition, edition);
    assert_eq!(fs::read(book.join("source.ndjson")).unwrap(), corpus(2));
    assert!(!suffix(&book, ".old").exists());
    assert!(!suffix(&book, ".new").exists());
    assert_ne!(suffix(&book, ".new"), suffix(&home.path().join("chat.2"), ".new"));
    catch_up(config);
}

#[test]
fn another_boot_publishes_the_new_edition_before_running() {
    let home = tempfile::tempdir().unwrap();
    let mut config = fixture(home.path(), 1);
    catch_up(config.clone());
    config.boot_id = 17;
    let actor = ChatActor::spawn(config);
    wait_health(&actor.handle, crate::life::Health::Running);
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 2);
    actor.join();
}

pub(super) fn rebuild_point(point: &str) {
    if std::env::var("ACPMUX_TEST_REBUILD_POINT").ok().as_deref() == Some(point) {
        stop_for_kill();
    }
}
fn stop_for_kill() {
    println!("ACTOR_CUT_READY");
    std::io::stdout().flush().unwrap();
    let mut byte = [0];
    std::io::stdin().read_exact(&mut byte).unwrap();
}

#[test]
#[ignore = "subprocess helper, driven by kill tests"]
fn killed_actor_worker() {
    let book = PathBuf::from(std::env::var_os("ACPMUX_TEST_BOOK").unwrap());
    let config = config_at(&book);
    if std::env::var_os("ACPMUX_TEST_REBUILD_POINT").is_some() {
        rebuild(config);
        return;
    }
    let cut: usize = std::env::var("ACPMUX_TEST_LINE").unwrap().parse().unwrap();
    let raw = fs::read(book.join("source.ndjson")).unwrap();
    let mut state = open_state(config).unwrap();
    let mut place = 0;
    for (index, line) in raw.split_inclusive(|byte| *byte == b'\n').enumerate() {
        let end = place + line.len() as u64;
        apply_line(&mut state, line.strip_suffix(b"\n").unwrap(), place, end, end - place).unwrap();
        if index + 1 == cut {
            stop_for_kill();
        }
        place = end;
    }
}
fn kill_at(book: &Path, line: Option<usize>, point: Option<&str>) {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", "chat::tests::killed_actor_worker", "--ignored", "--nocapture"])
        .env("ACPMUX_TEST_BOOK", book)
        .stdout(Stdio::piped())
        .stdin(Stdio::piped());
    if let Some(line) = line {
        command.env("ACPMUX_TEST_LINE", line.to_string());
    }
    if let Some(point) = point {
        command.env("ACPMUX_TEST_REBUILD_POINT", point);
    }
    let mut child = command.spawn().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (send, receive) = mpsc::channel();
    let reader = thread::spawn(move || {
        let ready = BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| line.contains("ACTOR_CUT_READY"));
        let _ = send.send(ready);
    });
    let ready = receive.recv_timeout(Duration::from_secs(15)).unwrap_or(false);
    if child.try_wait().unwrap().is_none() {
        child.kill().unwrap();
    }
    assert!(!child.wait().unwrap().success());
    reader.join().unwrap();
    assert!(ready, "worker did not reach the selected kill point within 15 seconds");
}

#[test]
fn fifty_actor_kills_replay_the_same_rows_once() {
    let home = tempfile::tempdir().unwrap();
    let clean = home.path().join("clean");
    catch_up(fixture(&clean, 6));
    let expected = rows(&clean);
    for cut in 1..=50 {
        let book = home.path().join(format!("kill-{cut}"));
        let config = fixture(&book, 6);
        kill_at(&book, Some(cut), None);
        catch_up(config);
        assert_eq!(rows(&book), expected, "kill after line {cut}");
    }
}

#[test]
fn ten_rebuild_kills_resume_one_edition_and_keep_raw() {
    let home = tempfile::tempdir().unwrap();
    let clean = home.path().join("clean");
    catch_up(fixture(&clean, 2));
    let expected = rows(&clean);
    for point in [
        "basis",
        "opened",
        "chunk",
        "caught-up",
        "raw-linked",
        "edition-chosen",
        "committed",
        "closed",
        "old-renamed",
        "new-renamed",
    ] {
        let book = home.path().join(point);
        let config = fixture(&book, 2);
        catch_up(config.clone());
        fs::write(book.join("folds.idx"), []).unwrap();
        kill_at(&book, None, Some(point));
        if suffix(&book, ".new").exists() {
            rebuild(config.clone());
        }
        catch_up(config);
        assert_eq!(rows(&book), expected, "kill at {point}");
        assert_eq!(log::CheckpointHead::read(&book).unwrap().unwrap().edition, 1);
        assert_eq!(fs::read(book.join("source.ndjson")).unwrap(), corpus(2));
        assert!(!suffix(&book, ".old").exists());
    }
}

struct FaultSource {
    inner: source::FileSource,
    attempts: Arc<AtomicU64>,
    fail_until: Arc<AtomicU64>,
    panic_once: bool,
}
impl source::RawSource for FaultSource {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<source::Chunk> {
        let attempt = self.attempts.fetch_add(1, Ordering::SeqCst);
        assert!(!(self.panic_once && attempt == 0), "one injected panic");
        if attempt < self.fail_until.load(Ordering::SeqCst) {
            return Err(std::io::Error::other("deterministic failing line"));
        }
        self.inner.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> std::io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> std::io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
}
fn faulty_config(book: &Path, panic_once: bool, fail_until: Arc<AtomicU64>) -> ChatConfig {
    let mut config = fixture(book, 1);
    let raw = book.join("source.ndjson");
    let attempts = Arc::new(AtomicU64::new(0));
    config.source_factory = Arc::new(move || {
        Ok(Box::new(FaultSource {
            inner: source::FileSource::open(&raw)?,
            attempts: attempts.clone(),
            fail_until: fail_until.clone(),
            panic_once,
        }))
    });
    config.supervision = crate::life::Policy {
        first_wait: Duration::from_millis(5),
        max_wait: Duration::from_millis(20),
        failed_wait: Duration::from_millis(100),
        ..crate::life::Policy::default()
    };
    config
}

#[test]
fn one_panicking_line_reopens_then_books_once() {
    let home = tempfile::tempdir().unwrap();
    let actor = ChatActor::spawn(faulty_config(home.path(), true, Arc::new(AtomicU64::new(0))));
    wait_health(&actor.handle, crate::life::Health::Running);
    assert_eq!(actor.handle.failures(), 1);
    actor.join();
    assert!(!rows(home.path()).is_empty());
}

#[test]
fn five_failures_mark_failed_then_a_successful_retry_clears_it() {
    let home = tempfile::tempdir().unwrap();
    let fail_until = Arc::new(AtomicU64::new(u64::MAX));
    let actor = ChatActor::spawn(faulty_config(home.path(), false, fail_until.clone()));
    wait_health(&actor.handle, crate::life::Health::Failed);
    assert_eq!(actor.handle.failures(), 5);
    assert!(matches!(actor.handle.wake(), Err(ChatError::Failed)));
    fail_until.store(0, Ordering::SeqCst);
    wait_health(&actor.handle, crate::life::Health::Running);
    actor.handle.wake().unwrap();
    actor.join();
    assert!(!rows(home.path()).is_empty());
}

#[test]
fn registry_evicts_a_failed_actor_without_waiting_for_retry() {
    let home = tempfile::tempdir().unwrap();
    let registry = crate::registry::Registry::new();
    let mut config = faulty_config(home.path(), false, Arc::new(AtomicU64::new(u64::MAX)));
    config.supervision.failed_wait = Duration::from_secs(60);
    let handle = registry.hydrate(config);
    wait_health(&handle, crate::life::Health::Failed);
    let started = Instant::now();
    assert!(registry.evict("chat"));
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(registry.is_empty());
}

#[test]
fn simultaneous_registry_lookups_start_only_one_writer() {
    let home = tempfile::tempdir().unwrap();
    let config = fixture(home.path(), 1);
    let starts = Arc::new(AtomicU64::new(0));
    let inner = config.source_factory.clone();
    let counter = starts.clone();
    let config = config.with_source_factory(Arc::new(move || {
        counter.fetch_add(1, Ordering::SeqCst);
        inner()
    }));
    let registry = crate::registry::Registry::new();
    let barrier = Arc::new(std::sync::Barrier::new(8));
    thread::scope(|scope| {
        for _ in 0..8 {
            let barrier = barrier.clone();
            let config = config.clone();
            let registry = registry.clone();
            scope.spawn(move || {
                barrier.wait();
                registry.hydrate(config)
            });
        }
    });
    wait_health(&registry.get("chat").unwrap(), crate::life::Health::Running);
    assert_eq!(starts.load(Ordering::SeqCst), 1);
    assert!(registry.evict("chat"));
}

fn gap_places(bytes: &[u8], _: u64) -> std::io::Result<std::ops::Range<u64>> {
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(std::io::Error::other)?;
    let start = value["seq"].as_u64().unwrap() * 10;
    Ok(start..start + 1)
}
struct GapSource {
    lines: Arc<Vec<Vec<u8>>>,
    reads: Arc<AtomicU64>,
    stamp: Arc<AtomicU64>,
    flip_after: Arc<AtomicU64>,
    first_gate: Arc<Mutex<Option<Receiver<()>>>>,
    progress: Option<mpsc::Sender<u64>>,
}
impl source::RawSource for GapSource {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<source::Chunk> {
        let reads = self.reads.fetch_add(1, Ordering::SeqCst) + 1;
        if let Some(progress) = &self.progress {
            let _ = progress.send(reads);
        }
        if reads == 1
            && let Some(gate) = self.first_gate.lock().unwrap().take()
        {
            gate.recv().unwrap();
        }
        if reads == self.flip_after.load(Ordering::SeqCst) {
            self.stamp.store(2, Ordering::SeqCst);
        }
        let index = (place / 10) as usize;
        let bytes = self.lines.get(index).cloned().unwrap_or_default();
        Ok(source::Chunk::with_stamp(
            bytes,
            0,
            gap_places,
            index + 1 >= self.lines.len(),
            self.lines.len() as u64 * 10 + 1,
            self.stamp.load(Ordering::SeqCst),
        ))
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        Ok(place == 0 || (place % 10 == 1 && place / 10 <= self.lines.len() as u64))
    }
    fn hint(&self) -> std::io::Result<u64> {
        Ok(self.lines.len() as u64 * 10 + 1)
    }
    fn sync_through(&mut self, _: u64) -> std::io::Result<()> {
        Ok(())
    }
    fn identity(&self) -> &[u8] {
        b"gap-source"
    }
    fn stamp(&self) -> u64 {
        self.stamp.load(Ordering::SeqCst)
    }
}
struct GapFixture {
    config: ChatConfig,
    reads: Arc<AtomicU64>,
    stamp: Arc<AtomicU64>,
    flip_after: Arc<AtomicU64>,
    gate: Arc<Mutex<Option<Receiver<()>>>>,
    progress: Receiver<u64>,
}
fn gap_fixture(book: &Path, raw: &[u8]) -> GapFixture {
    let lines = Arc::new(raw.split_inclusive(|b| *b == b'\n').map(Vec::from).collect::<Vec<_>>());
    let reads = Arc::new(AtomicU64::new(0));
    let stamp = Arc::new(AtomicU64::new(1));
    let flip_after = Arc::new(AtomicU64::new(u64::MAX));
    let gate = Arc::new(Mutex::new(None));
    let (progress_tx, progress) = mpsc::channel();
    let (r, s, f, g) = (reads.clone(), stamp.clone(), flip_after.clone(), gate.clone());
    let config =
        ChatConfig::new("gap", book, Harness::V1).with_source_factory(Arc::new(move || {
            Ok(Box::new(GapSource {
                lines: lines.clone(),
                reads: r.clone(),
                stamp: s.clone(),
                flip_after: f.clone(),
                first_gate: g.clone(),
                progress: Some(progress_tx.clone()),
            }))
        }));
    GapFixture { config, reads, stamp, flip_after, gate, progress }
}

#[test]
fn source_places_can_have_gaps_and_resume_exactly() {
    let home = tempfile::tempdir().unwrap();
    let fixture = gap_fixture(home.path(), &corpus(3));
    catch_up(fixture.config.clone());
    let first = rows(home.path());
    let saved = log::saved_checkpoint(home.path()).unwrap().unwrap();
    let checkpoint = Checkpoint::from_recovered(&saved).unwrap();
    assert_eq!(checkpoint.cursors[0].place, 271);
    catch_up(fixture.config);
    assert_eq!(rows(home.path()), first);
}

#[test]
fn full_mailbox_remains_responsive_over_one_hundred_thousand_lines() {
    let home = tempfile::tempdir().unwrap();
    let mut raw = Vec::new();
    writeln!(
        raw,
        r#"{{"seq":1,"at":0,"dir":"mux","kind":"turn_started","msg":{{"turnId":"load"}}}}"#
    )
    .unwrap();
    for seq in 2..=100_000 {
        writeln!(
            raw,
            "{{\"seq\":{seq},\"at\":{seq},\"dir\":\"mux\",\"kind\":\"host_notice\",\"msg\":{{}}}}"
        )
        .unwrap();
    }
    let fixture = gap_fixture(home.path(), &raw);
    let (go, gate) = mpsc::channel();
    *fixture.gate.lock().unwrap() = Some(gate);
    let actor = ChatActor::spawn(fixture.config);
    assert_eq!(fixture.progress.recv_timeout(Duration::from_secs(5)).unwrap(), 1);
    for _ in 0..256 {
        actor.handle.wake().unwrap();
    }
    assert!(matches!(actor.handle.wake(), Err(ChatError::MailboxFull)));
    let done = Arc::new(AtomicBool::new(false));
    let producer_done = done.clone();
    let handle = actor.handle.clone();
    let producer = thread::spawn(move || {
        while !producer_done.load(Ordering::Acquire) {
            match handle.wake() {
                Ok(()) | Err(ChatError::MailboxFull) => thread::yield_now(),
                Err(error) => panic!("producer failed: {error}"),
            }
        }
    });
    go.send(()).unwrap();
    while fixture.progress.recv_timeout(Duration::from_secs(20)).unwrap() < 100_000 {}
    done.store(true, Ordering::Release);
    producer.join().unwrap();
    // Stop producing before Close so the request has a slot; joining still drains no
    // raw bytes on behalf of the test. Every line was already delivered by the actor.
    wait_health(&actor.handle, crate::life::Health::Running);
    actor.join();
    let recovered = log::saved_checkpoint(home.path()).unwrap().unwrap();
    let checkpoint = Checkpoint::from_recovered(&recovered).unwrap();
    assert_eq!(checkpoint.cursors[0].place, 1_000_001);
    assert!(fixture.reads.load(Ordering::SeqCst) >= 100_000);
    let (log, _) = Log::open(home.path(), Options::default()).unwrap();
    assert_eq!(log.max_row(), 99_999);
    assert_eq!(log.last_seq(), 99_999);
}

#[test]
fn changed_stamp_during_rebuild_cuts_staging_and_advances_once() {
    let home = tempfile::tempdir().unwrap();
    let fixture = gap_fixture(home.path(), &corpus(2));
    catch_up(fixture.config.clone());
    let expected = rows(home.path());
    fs::write(home.path().join("folds.idx"), []).unwrap();
    fixture.flip_after.store(fixture.reads.load(Ordering::SeqCst) + 4, Ordering::SeqCst);
    rebuild(fixture.config.clone());
    assert_eq!(rows(home.path()), expected);
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 2);
    assert_eq!(fixture.stamp.load(Ordering::SeqCst), 2);
    catch_up(fixture.config);
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 2);
}

#[test]
fn changed_stamp_at_open_cuts_and_advances_before_running() {
    let home = tempfile::tempdir().unwrap();
    let fixture = gap_fixture(home.path(), &corpus(2));
    catch_up(fixture.config.clone());
    fixture.stamp.store(2, Ordering::SeqCst);
    let actor = ChatActor::spawn(fixture.config);
    wait_health(&actor.handle, crate::life::Health::Running);
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 2);
    actor.join();
}

#[test]
fn truncated_source_cursor_rebuilds_with_a_new_edition() {
    let home = tempfile::tempdir().unwrap();
    let config = fixture(home.path(), 2);
    catch_up(config.clone());
    fs::write(home.path().join("source.ndjson"), corpus(1)).unwrap();
    let actor = ChatActor::spawn(config);
    wait_health(&actor.handle, crate::life::Health::Running);
    actor.join();
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 2);
    let clean = tempfile::tempdir().unwrap();
    catch_up(fixture(clean.path(), 1));
    assert_eq!(rows(home.path()), rows(clean.path()));
}

#[test]
fn a_damaged_checkpoint_head_uses_injected_random_edition_once() {
    let home = tempfile::tempdir().unwrap();
    let config = fixture(home.path(), 2).with_edition_random(Arc::new(|| 77));
    catch_up(config.clone());
    fs::write(home.path().join("checkpoint"), b"lost head").unwrap();
    rebuild(config.clone());
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 77);
    catch_up(config);
    assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, 77);
}

fn percentile(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[(values.len() * 95 / 100).min(values.len() - 1)]
}

#[test]
#[ignore = "Linux gate-profile ratio fixture: 40 and 2M settled rows"]
fn actor_line_and_checkpoint_open_gate() {
    let mut measures = Vec::new();
    for count in [40u64, 2_000_000] {
        let home = tempfile::tempdir().unwrap();
        let config = ChatConfig::new("gate", home.path(), Harness::V1);
        let mut state = open_state(config.clone()).unwrap();
        // Feed the actual translator and body/log writer. The synthetic source has
        // no persistent raw cursor; checkpoint once after setup, outside measurement.
        for seq in 1..=count {
            let line = format!(
                "{{\"seq\":{seq},\"at\":1000,\"dir\":\"mux\",\"kind\":\"stopped\",\"msg\":{{}}}}"
            );
            apply_ops(&mut state, line.as_bytes(), 0, 0, 0, false).unwrap();
        }
        assert_eq!(state.log.max_row(), count);
        checkpoint(&mut state).unwrap();
        let mut rounds = Vec::new();
        let mut all = Vec::new();
        for round in 0..5u64 {
            let mut samples = Vec::new();
            for sample in 1..=100u64 {
                let seq = count + round * 100 + sample;
                let line = format!(
                    "{{\"seq\":{seq},\"at\":1000,\"dir\":\"mux\",\"kind\":\"stopped\",\"msg\":{{}}}}"
                );
                let start = Instant::now();
                apply_ops(&mut state, line.as_bytes(), 0, 0, 0, false).unwrap();
                samples.push(start.elapsed().as_nanos());
            }
            all.extend(samples.iter().copied());
            rounds.push(percentile(&mut samples));
        }
        let line_best = *rounds.iter().min().unwrap();
        let line_all = percentile(&mut all);
        checkpoint(&mut state).unwrap();
        drop(state);
        let mut rounds = Vec::new();
        let mut all = Vec::new();
        for _ in 0..5 {
            let mut samples = Vec::new();
            for _ in 0..50 {
                let start = Instant::now();
                let opened = open_state(config.clone()).unwrap();
                samples.push(start.elapsed().as_nanos());
                assert_eq!(opened.log.stats().bytes_read, 0);
                drop(opened);
            }
            all.extend(samples.iter().copied());
            rounds.push(percentile(&mut samples));
        }
        measures.push((line_best, line_all, *rounds.iter().min().unwrap(), percentile(&mut all)));
    }
    let (small, god) = (measures[0], measures[1]);
    for (name, small, god, all) in [
        ("v2.pr03a3.actor_line", small.0, god.0, god.1),
        ("v2.pr03a3.checkpoint_open", small.2, god.2, god.3),
    ] {
        println!(
            "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{all},\"unit\":\"ns\"}}"
        );
        assert!((god as f64) <= small as f64 * 1.2, "{name} best p95");
        assert!((all as f64) <= small as f64 * 2.0, "{name} aggregate p95");
    }
}

#[test]
fn deterministic_translation_failure_is_counted_five_times_without_advancing_raw() {
    let home = tempfile::tempdir().unwrap();
    let mut config = fixture(home.path(), 0);
    fs::write(home.path().join("source.ndjson"), b"not json\n").unwrap();
    config.supervision.first_wait = Duration::from_millis(5);
    config.supervision.max_wait = Duration::from_millis(20);
    let actor = ChatActor::spawn(config);
    wait_health(&actor.handle, crate::life::Health::Failed);
    assert_eq!(actor.handle.failures(), 5);
    actor.join();
    let saved = log::saved_checkpoint(home.path()).unwrap().unwrap();
    let checkpoint = Checkpoint::from_recovered(&saved).unwrap();
    // The source is named from the first checkpoint; its cursor never moved past the line.
    assert!(checkpoint.cursors.iter().all(|cursor| cursor.place == 0));
    assert_eq!(checkpoint.last_row, 0);
}

#[test]
fn replaced_raw_after_a_killed_link_never_swaps_the_old_inode_back() {
    for point in ["raw-linked", "committed", "closed"] {
        let home = tempfile::tempdir().unwrap();
        let book = home.path().join("book");
        let config = fixture(&book, 2);
        catch_up(config.clone());
        fs::write(book.join("folds.idx"), []).unwrap();
        kill_at(&book, None, Some(point));
        let replacement = home.path().join("replacement.ndjson");
        fs::write(&replacement, corpus(1)).unwrap();
        fs::rename(&replacement, book.join("source.ndjson")).unwrap();
        #[cfg(unix)]
        let inode = {
            use std::os::unix::fs::MetadataExt;
            fs::metadata(book.join("source.ndjson")).unwrap().ino()
        };
        rebuild(config);
        assert_eq!(fs::read(book.join("source.ndjson")).unwrap(), corpus(1));
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            assert_eq!(fs::metadata(book.join("source.ndjson")).unwrap().ino(), inode);
        }
        assert_eq!(log::CheckpointHead::read(&book).unwrap().unwrap().edition, 2);
        let clean = home.path().join("clean");
        catch_up(fixture(&clean, 1));
        assert_eq!(rows(&book), rows(&clean));
    }
}

#[test]
fn rebuilding_an_absent_book_with_an_external_file_source_succeeds() {
    let home = tempfile::tempdir().unwrap();
    let raw = home.path().join("raw.ndjson");
    fs::write(&raw, corpus(1)).unwrap();
    let config = ChatConfig::new("chat", home.path().join("missing"), Harness::V1)
        .with_source_factory(Arc::new(move || Ok(Box::new(source::FileSource::open(&raw)?))));
    rebuild(config.clone());
    assert!(!rows(&config.book).is_empty());
    assert!(home.path().join("raw.ndjson").exists());
}

#[test]
fn reopening_in_the_same_boot_keeps_the_checkpoint_bytes() {
    let home = tempfile::tempdir().unwrap();
    let config = fixture(home.path(), 2);
    catch_up(config.clone());
    let before = fs::read(home.path().join("checkpoint")).unwrap();
    let state = open_state(config).unwrap();
    assert_eq!(state.log.stats().checkpoints, 0);
    assert_eq!(fs::read(home.path().join("checkpoint")).unwrap(), before);
}

#[test]
fn damage_rebuilds_choose_the_proven_or_next_edition() {
    let home = tempfile::tempdir().unwrap();
    let clean = home.path().join("clean");
    catch_up(fixture(&clean, 2));
    let expected = rows(&clean);
    for (damage, edition) in [("segment", 1), ("checkpoint-body", 2), ("folds", 1)] {
        let book = home.path().join(damage);
        let config = fixture(&book, 2);
        catch_up(config.clone());
        match damage {
            "segment" => {
                let path = book.join("rows/000001.seg");
                let mut bytes = fs::read(&path).unwrap();
                bytes[0] ^= 1;
                fs::write(path, bytes).unwrap();
            }
            "checkpoint-body" => {
                let path = book.join("checkpoint");
                let mut bytes = fs::read(&path).unwrap();
                *bytes.last_mut().unwrap() ^= 1;
                fs::write(path, bytes).unwrap();
            }
            "folds" => fs::write(book.join("folds.idx"), []).unwrap(),
            _ => unreachable!(),
        }
        let actor = ChatActor::spawn(config);
        wait_health(&actor.handle, crate::life::Health::Running);
        actor.join();
        assert_eq!(rows(&book), expected, "{damage}");
        assert_eq!(log::CheckpointHead::read(&book).unwrap().unwrap().edition, edition, "{damage}");
    }
}

#[test]
fn repeated_head_loss_never_reuses_a_constant_edition() {
    let home = tempfile::tempdir().unwrap();
    let next = AtomicU64::new(76);
    let config = fixture(home.path(), 1)
        .with_edition_random(Arc::new(move || next.fetch_add(1, Ordering::SeqCst) as u32 + 1));
    catch_up(config.clone());
    for expected in [77, 78] {
        fs::write(home.path().join("checkpoint"), b"lost head").unwrap();
        rebuild(config.clone());
        assert_eq!(log::CheckpointHead::read(home.path()).unwrap().unwrap().edition, expected);
    }
}

fn large_body_raw() -> Vec<u8> {
    let mut events: Vec<serde_json::Value> =
        SEED.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    events[6]["msg"]["params"]["update"]["content"][0]["content"]["text"] =
        "a".repeat(20_000).into();
    let mut replacement = events[6].clone();
    events[6]["msg"]["params"]["update"]["status"] = "pending".into();
    replacement["msg"]["params"]["update"]["content"][0]["content"]["text"] =
        "b".repeat(30_000).into();
    events.insert(7, replacement);
    let mut raw = Vec::new();
    for (index, event) in events.iter_mut().enumerate() {
        event["seq"] = (index as u64 + 1).into();
        serde_json::to_writer(&mut raw, event).unwrap();
        raw.push(b'\n');
    }
    raw
}
fn final_blobs(book: &Path) -> BTreeMap<String, Vec<u8>> {
    fs::read_dir(book.join("blobs"))
        .unwrap()
        .map(Result::unwrap)
        .filter(|entry| entry.file_type().unwrap().is_file())
        .map(|entry| (entry.file_name().into_string().unwrap(), fs::read(entry.path()).unwrap()))
        .collect()
}

#[test]
fn large_body_replacement_survives_every_raw_line_kill() {
    let home = tempfile::tempdir().unwrap();
    let clean = home.path().join("clean");
    let raw = large_body_raw();
    fs::create_dir(&clean).unwrap();
    fs::write(clean.join("source.ndjson"), &raw).unwrap();
    catch_up(config_at(&clean));
    let expected = rows(&clean);
    let blobs = final_blobs(&clean);
    assert!(!blobs.is_empty(), "fixture must spill a body");
    for cut in 1..=10 {
        let book = home.path().join(format!("blob-kill-{cut}"));
        fs::create_dir(&book).unwrap();
        fs::write(book.join("source.ndjson"), &raw).unwrap();
        kill_at(&book, Some(cut), None);
        catch_up(config_at(&book));
        assert_eq!(rows(&book), expected, "kill after {cut}");
        assert_eq!(final_blobs(&book), blobs, "blob after {cut}");
    }
}
