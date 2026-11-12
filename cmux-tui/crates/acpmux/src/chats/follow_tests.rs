//! A followed chat's text is the text a whole read makes, after every append, cut, replace and
//! window move, and an append reads only what was appended.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume};

use super::*;

fn chat(harness: AdapterKind, path: &Path, updated_ms: i64) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness,
            session_id: "s".to_owned(),
            title: None,
            title_source: None,
            cwd: None,
            created_ms: None,
            updated_ms,
            message_count: None,
            source_path: path.to_path_buf(),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        },
        accounts: Vec::new(),
        roots: Vec::new(),
    }
}

/// The window's messages as `_acpmux/chat_transcript` numbers them: (turn, answer, text).
fn shown(doc: &Doc) -> Vec<(u32, bool, String)> {
    (doc.live as usize..doc.messages.len())
        .map(|i| {
            let m = doc.messages[i];
            (m.turn - doc.first_turn, m.answer, doc.message(i).to_owned())
        })
        .collect()
}

struct Followed {
    text: ChatText,
    harness: AdapterKind,
    path: PathBuf,
    stamp: i64,
    _dir: tempfile::TempDir,
}

impl Followed {
    fn new(harness: AdapterKind) -> Self {
        let dir = tempfile::tempdir().expect("dir");
        let path = dir.path().join("t.jsonl");
        std::fs::write(&path, "").expect("write");
        let text = ChatText::new(dir.path().join("text.json"));
        Self { text, harness, path, stamp: 0, _dir: dir }
    }

    fn key(&self) -> String {
        format!("{}:s", self.harness.id())
    }

    fn append(&self, bytes: &str) {
        let mut file = std::fs::OpenOptions::new().append(true).open(&self.path).expect("open");
        file.write_all(bytes.as_bytes()).expect("append");
    }

    /// Follows the chat once and checks its text is a whole read's.
    fn check(&mut self, why: &str) {
        self.stamp += 1;
        let chats = [chat(self.harness, &self.path, self.stamp)];
        self.text.follow(&chats, &|_| panic!("a followed chat is not read whole by `read`"));
        let whole = super::super::transcript_turns(&chats[0].entry).expect("readable");
        let want = shown(&Doc::of_turns(Stamp::of(&chats[0].entry), &whole, 0));
        let inner = lock(&self.text.inner);
        let doc = inner.docs.get(&self.key()).expect("held");
        assert!(doc.is_sound(), "{why}: sound");
        assert_eq!(shown(doc), want, "{why}");
    }

    fn bytes(&self) -> u64 {
        self.text.follow_bytes(&self.key()).expect("followed")
    }
}

/// A small deterministic generator.
struct Rng(u64);

impl Rng {
    fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % n
    }
}

fn claude_line(rng: &mut Rng, i: u64) -> String {
    let at = format!("2026-10-01T01:{:02}:{:02}.000Z", i / 60 % 60, i % 60);
    match rng.below(8) {
        0 | 1 => format!(
            r#"{{"type":"user","timestamp":"{at}","message":{{"role":"user","content":"prompt {i} Fix   the sidebar"}}}}"#
        ),
        2 | 3 => format!(
            r#"{{"type":"assistant","timestamp":"{at}","message":{{"role":"assistant","content":[{{"type":"text","text":"answer {i}\n\nthe row is NaN"}}],"stop_reason":"end_turn"}}}}"#
        ),
        4 => format!(
            r#"{{"type":"assistant","timestamp":"{at}","message":{{"content":[{{"type":"tool_use","id":"t{i}","name":"Bash","input":{{"command":"ls"}}}}]}}}}"#
        ),
        5 => format!(
            r#"{{"type":"user","timestamp":"{at}","message":{{"content":[{{"type":"tool_result","tool_use_id":"t{i}","content":"out {i}"}}]}}}}"#
        ),
        6 => format!(r#"{{"type":"user","isSidechain":true,"message":{{"content":"side {i}"}}}}"#),
        _ => "not json".to_owned(),
    }
}

fn codex_line(rng: &mut Rng, i: u64, events: bool) -> String {
    let kind = rng.below(if events { 4 } else { 2 });
    match kind {
        0 => format!(
            r#"{{"type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"item prompt {i}"}}]}}}}"#
        ),
        1 => format!(
            r#"{{"type":"response_item","payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"item answer {i}"}}]}}}}"#
        ),
        2 => format!(
            r#"{{"type":"event_msg","payload":{{"type":"user_message","message":"event prompt {i}"}}}}"#
        ),
        _ => format!(
            r#"{{"type":"event_msg","payload":{{"type":"agent_message","message":"event answer {i}"}}}}"#
        ),
    }
}

#[test]
fn a_followed_claude_chat_holds_a_whole_reads_text_after_every_append() {
    let mut chat = Followed::new(AdapterKind::ClaudeCode);
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    // Past the turn window, so turns leave it as a whole read drops them.
    for i in 0..1_200 {
        let line = format!("{}\n", claude_line(&mut rng, i));
        if rng.below(5) == 0 {
            // Half a line first: the writer is still writing it.
            let (head, tail) = line.split_at(line.len() / 2);
            chat.append(head);
            chat.check(&format!("line {i}, half written"));
            chat.append(tail);
        } else {
            chat.append(&line);
        }
        if rng.below(3) == 0 {
            chat.check(&format!("line {i}"));
        }
    }
    chat.check("the end");
    let inner = lock(&chat.text.inner);
    let newest = shown(inner.docs.get(&chat.key()).expect("held")).last().map(|m| m.0);
    assert_eq!(newest, Some(crate::adopt_replay::MAX_TURNS as u32 - 1), "the window is full");
}

#[test]
fn a_followed_codex_chat_holds_a_whole_reads_text_also_when_its_turns_move_to_events() {
    let mut chat = Followed::new(AdapterKind::Codex);
    let mut rng = Rng(0x2545_f491_4f6c_dd1d);
    // Items only (a rollout without event messages), then event messages too: the turns move.
    for i in 0..400 {
        chat.append(&format!("{}\n", codex_line(&mut rng, i, i >= 150)));
        if rng.below(2) == 0 {
            chat.check(&format!("line {i}"));
        }
    }
    chat.check("the end");
}

#[test]
fn an_append_reads_only_what_was_appended() {
    let mut chat = Followed::new(AdapterKind::ClaudeCode);
    let mut rng = Rng(7);
    let mut whole = String::new();
    for i in 0..2_000 {
        whole.push_str(&format!("{}\n", claude_line(&mut rng, i)));
    }
    chat.append(&whole);
    chat.check("first read");
    assert_eq!(chat.bytes(), whole.len() as u64, "the first read is whole");
    for i in 2_000..2_050 {
        let line = format!("{}\n", claude_line(&mut rng, i));
        let before = chat.bytes();
        chat.append(&line);
        chat.check(&format!("line {i}"));
        assert_eq!(chat.bytes() - before, line.len() as u64, "line {i}: only the line is read");
    }
}

#[test]
fn a_cut_or_replaced_transcript_is_read_whole_again() {
    let mut chat = Followed::new(AdapterKind::ClaudeCode);
    let mut rng = Rng(11);
    let lines: Vec<String> = (0..300).map(|i| format!("{}\n", claude_line(&mut rng, i))).collect();
    chat.append(&lines.concat());
    chat.check("first read");
    // Cut shorter than the last read's end.
    std::fs::write(&chat.path, lines[..100].concat()).expect("cut");
    chat.check("cut");
    // Rewritten in place, as long or longer: a line no longer ends where the last read stopped.
    let rewritten = format!("x{}", lines[..200].concat());
    std::fs::write(&chat.path, rewritten).expect("rewrite");
    chat.check("rewritten in place");
    // Replaced by another file (another inode) with other lines.
    let other = chat.path.with_extension("new");
    std::fs::write(&other, lines[150..].concat()).expect("other");
    std::fs::rename(&other, &chat.path).expect("replace");
    chat.check("replaced");
}

#[test]
fn turns_out_of_the_newest_bytes_leave_the_window_as_a_whole_read_drops_them() {
    let mut chat = Followed::new(AdapterKind::ClaudeCode);
    let filler = |i: u64| {
        // A tool result of about 1 MB: no turn, only bytes.
        let out = "o".repeat(1 << 20);
        format!(
            r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"t{i}","content":"{out}"}}]}}}}"#
        ) + "\n"
    };
    let prompt = |i: u64| {
        format!(r#"{{"type":"user","message":{{"role":"user","content":"prompt {i}"}}}}"#) + "\n"
    };
    let mut i = 0;
    let mut big = String::new();
    while (big.len() as u64) < crate::adopt_replay::MAX_BYTES - (4 << 20) {
        big.push_str(&prompt(i));
        big.push_str(&filler(i));
        i += 1;
    }
    chat.append(&big);
    chat.check("under the bytes window");
    // Each step moves the cut past one more turn.
    for _ in 0..8 {
        chat.append(&(prompt(i) + &filler(i)));
        i += 1;
        chat.check(&format!("turn {i}"));
    }
}

#[test]
fn more_than_the_window_appended_between_two_reads_numbers_its_turns_as_a_whole_read() {
    let mut chat = Followed::new(AdapterKind::ClaudeCode);
    let prompt = |i: usize| {
        format!(r#"{{"type":"user","message":{{"role":"user","content":"prompt {i}"}}}}"#) + "\n"
    };
    chat.append(&(0..10).map(prompt).collect::<String>());
    chat.check("ten turns");
    // More than twice the window at once: the fold lets go of the open turn while reading.
    chat.append(&(10..460).map(prompt).collect::<String>());
    chat.check("450 more at once");
    let found = chat.text.search(&Needle::parse("459").expect("words"));
    assert_eq!(found.len(), 1, "the newest turn is found");
}

#[test]
fn a_long_followed_chat_holds_a_whole_reads_newest_messages_in_its_bound() {
    let mut chat = Followed::new(AdapterKind::ClaudeCode);
    let words = "w ".repeat(4_000);
    for i in 0..400 {
        chat.append(
            &(format!(
                r#"{{"type":"user","message":{{"role":"user","content":"prompt{i} {words}"}}}}"#
            ) + "\n"),
        );
        chat.check(&format!("prompt {i}"));
    }
    let needle = Needle::parse("prompt399").expect("words");
    let found = chat.text.search(&needle);
    let hit = ChatText::hit(found.values().next().expect("found"), &needle).expect("hit");
    assert_eq!(
        hit["turn"],
        json!(crate::adopt_replay::MAX_TURNS - 1),
        "numbered as the transcript"
    );
}
