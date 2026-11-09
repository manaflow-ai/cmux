use std::cell::RefCell;
use std::path::PathBuf;
use std::time::Instant;

use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume};

use super::*;

fn turn(prompt: &str, answer: &str) -> Turn {
    Turn { prompt: prompt.into(), answer: answer.into(), prompt_at: None, answer_at: None }
}

fn chat(id: &str, updated_ms: i64) -> IndexedChat {
    IndexedChat {
        entry: ChatEntry {
            harness: AdapterKind::Codex,
            session_id: id.to_owned(),
            title: Some(format!("chat {id}")),
            title_source: None,
            cwd: None,
            created_ms: None,
            updated_ms,
            message_count: None,
            source_path: PathBuf::from(format!("/nonexistent/{id}.jsonl")),
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        },
        accounts: Vec::new(),
        roots: Vec::new(),
    }
}

fn index() -> ChatText {
    ChatText::new(std::env::temp_dir().join(format!("acpmux-text-{}.json", uuid::Uuid::now_v7())))
}

fn needle(query: &str) -> Needle {
    Needle::parse(query).expect("words")
}

#[test]
fn every_word_in_one_message_any_case_the_newest_message_is_the_hit() {
    let doc = Doc::new(
        Stamp { updated_ms: 0, messages: None },
        &[turn("Fix the Sidebar", "The row is NaN."), turn("deploy", "the ROW again: nan")],
    );
    let words = needle("nan row");
    let found = doc.find(&words, &Matcher::new(&words)).expect("found");
    assert_eq!(found.matches, 2);
    let hit = &doc.messages[found.message as usize];
    assert_eq!((hit.turn, hit.answer), (1, true));
    // A word said many times in one message counts that message once (review of #38431, F3).
    let repeated = Doc::new(
        Stamp { updated_ms: 0, messages: None },
        &[turn("nan nan row nan", "row"), turn("x", "nan NaN nan row")],
    );
    assert_eq!(repeated.find(&words, &Matcher::new(&words)).map(|f| f.matches), Some(2));
    // One word too: the scan goes on past the message it found.
    let one = needle("nan");
    assert_eq!(repeated.find(&one, &Matcher::new(&one)).map(|f| f.matches), Some(2));
    // Words split between a prompt and its answer are no match.
    let split = needle("sidebar nan");
    assert_eq!(doc.find(&split, &Matcher::new(&split)), None);
    // A word that is not ASCII is read as `_acpmux/chats_search` reads it.
    let doc = Doc::new(Stamp { updated_ms: 0, messages: None }, &[turn("ΟΣ ok", "")]);
    let greek = needle("ος");
    assert!(Matcher::new(&greek).ascii.is_none());
    assert_eq!(doc.find(&greek, &Matcher::new(&greek)).map(|f| f.matches), Some(1));
}

#[test]
fn an_ascii_query_finds_a_letter_that_lowercases_to_ascii_also_after_a_restart() {
    // Review of #38431, F2: the ASCII pass is case-blind for ASCII only; `Needle` lowercases the
    // Kelvin sign to `k` and `İ` to `i` plus a dot, so these docs are read as `Needle` reads them.
    let text = index();
    text.update(&[chat("a", 1)], &|_| Some(vec![turn("x", "300 \u{212A}elvin")]));
    let kelvin = needle("kelvin");
    assert!(Matcher::new(&kelvin).ascii.is_some(), "an ASCII query");
    assert_eq!(text.search(&kelvin).len(), 1);
    let again = ChatText::new(text.path.clone());
    again.load();
    assert_eq!(again.search(&kelvin).len(), 1, "the flag is read again on load");
    // A doc with other non-ASCII text keeps the fast pass.
    let plain =
        Doc::new(Stamp { updated_ms: 0, messages: None }, &[turn("caf\u{e9} \u{2014} ok", "")]);
    assert!(!plain.folds_to_ascii);
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn a_long_chat_keeps_its_newest_messages() {
    let big = "w ".repeat(CHAT_BYTES / 4);
    let turns: Vec<Turn> = (0..4).map(|i| turn(&format!("prompt{i} {big}"), "")).collect();
    let doc = Doc::new(Stamp { updated_ms: 0, messages: None }, &turns);
    assert!(doc.text.len() <= CHAT_BYTES, "{}", doc.text.len());
    let turns: Vec<u32> = doc.messages.iter().map(|m| m.turn).collect();
    assert_eq!(turns.last(), Some(&3), "the newest turn is held");
    assert!(!turns.contains(&0), "the oldest is left out");
    assert!(doc.message(doc.messages.len() - 1).starts_with("prompt3"));
}

#[test]
fn a_chat_is_read_again_only_when_it_changed_and_a_gone_chat_is_dropped() {
    let text = index();
    let reads = RefCell::new(Vec::<String>::new());
    let read = |entry: &ChatEntry| {
        reads.borrow_mut().push(entry.session_id.clone());
        Some(vec![turn("hello", &format!("the answer of {}", entry.session_id))])
    };
    text.update(&[chat("a", 2), chat("b", 1)], &read);
    assert_eq!(*reads.borrow(), ["a", "b"]);
    let changed = text.subscribe();
    text.update(&[chat("a", 2), chat("b", 1)], &read);
    assert_eq!(reads.borrow().len(), 2, "nothing changed, nothing read");
    assert!(!changed.has_changed().unwrap(), "and windows are not told");
    text.update(&[chat("a", 3)], &read);
    assert_eq!(*reads.borrow(), ["a", "b", "a"]);
    assert!(changed.has_changed().unwrap());
    assert_eq!(text.held().0, 1, "b is gone");
    let found = text.search(&needle("ANSWER"));
    assert_eq!(found.keys().collect::<Vec<_>>(), ["codex:a"]);
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn a_query_is_answered_from_memory_once_until_the_text_changes() {
    let text = index();
    text.update(&[chat("a", 1)], &|_| Some(vec![turn("x", "the deploy failed")]));
    let first = text.search(&needle("deploy"));
    assert!(Arc::ptr_eq(&first, &text.search(&needle("DEPLOY"))), "the same words: kept");
    text.update(&[chat("a", 2)], &|_| Some(vec![turn("x", "fine now")]));
    assert!(text.search(&needle("deploy")).is_empty(), "the text changed: searched again");
    let _ = std::fs::remove_file(&text.path);
}

/// A key typed onto the query searches only the chats the query before found; a text change, a
/// key taken back or a word that is not inside the new ones searches every chat again.
#[test]
fn a_narrowing_query_searches_the_last_hits_until_the_text_changes() {
    let text = index();
    let said = |id: &str| match id {
        "a" => "the deploy failed",
        "b" => "a deep dive",
        _ => "nothing here",
    };
    let chats = |c_updated: i64| vec![chat("a", 1), chat("b", 1), chat("c", c_updated)];
    text.update(&chats(1), &|entry| Some(vec![turn("x", said(&entry.session_id))]));
    let keys = |found: &HashMap<String, Found>| {
        let mut keys: Vec<String> = found.keys().cloned().collect();
        keys.sort();
        keys
    };
    let at = text.scanned();
    assert_eq!(keys(&text.search(&needle("de"))), ["codex:a", "codex:b"]);
    assert_eq!(text.scanned() - at, 3, "the first key searches every chat");
    let at = text.scanned();
    assert_eq!(keys(&text.search(&needle("dep"))), ["codex:a"]);
    assert_eq!(text.scanned() - at, 2, "the next key searches the two the first found");
    let at = text.scanned();
    assert_eq!(keys(&text.search(&needle("DEPLOY fail"))), ["codex:a"]);
    assert_eq!(text.scanned() - at, 1, "a word added narrows too");
    // A chat now says the words: the text changed, so every chat is searched again.
    text.update(&chats(2), &|entry| {
        let said =
            if entry.session_id == "c" { "deploy failed again" } else { said(&entry.session_id) };
        Some(vec![turn("x", said)])
    });
    let at = text.scanned();
    assert_eq!(keys(&text.search(&needle("deploy failed"))), ["codex:a", "codex:c"]);
    assert_eq!(text.scanned() - at, 3, "the text changed: every chat");
    let at = text.scanned();
    assert_eq!(keys(&text.search(&needle("de"))), ["codex:a", "codex:b", "codex:c"]);
    assert_eq!(text.scanned() - at, 3, "a key taken back: every chat");
    let at = text.scanned();
    assert_eq!(keys(&text.search(&needle("dive"))), ["codex:b"]);
    assert_eq!(text.scanned() - at, 3, "a word that does not hold the last one: every chat");
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn a_hit_has_a_short_snippet_around_the_words_with_their_characters() {
    let text = index();
    let answer = format!(
        "{} The build broke because the Cache key changed. {}",
        "a ".repeat(80),
        "b ".repeat(80)
    );
    text.update(&[chat("a", 1)], &|_| Some(vec![turn("why", &answer)]));
    let words = needle("cache key");
    let found = text.search(&words);
    let hit = ChatText::hit(&found["codex:a"], &words).expect("hit");
    assert_eq!((hit["turn"].as_u64(), hit["role"].as_str()), (Some(0), Some("answer")));
    let snippet = hit["snippet"].as_str().expect("snippet");
    assert!(snippet.starts_with('…') && snippet.ends_with('…'), "{snippet}");
    assert!(snippet.chars().count() <= ROW_SNIPPET + 2, "{snippet}");
    let chars: Vec<char> = snippet.chars().collect();
    let lit: String = hit["highlights"]
        .as_array()
        .expect("highlights")
        .iter()
        .map(|at| chars[at.as_u64().unwrap() as usize])
        .collect();
    assert_eq!(lit, "Cachekey");
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn the_text_is_saved_private_and_read_back_and_chats_off_empty_it() {
    let text = index();
    text.update(&[chat("a", 1)], &|_| Some(vec![turn("x", "kept across a restart")]));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&text.path).expect("saved").permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let again = ChatText::new(text.path.clone());
    again.load();
    assert_eq!(again.search(&needle("restart")).len(), 1);
    // The saved copy names the stamp it was read at: an unchanged chat is not read again.
    again.update(&[chat("a", 1)], &|_| panic!("read again"));
    again.update(&[], &|_| None);
    assert_eq!(again.held(), (0, 0));
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn a_gone_chat_leaves_the_saved_copy_at_once_and_the_first_pass_marks_it_filled() {
    let text = index();
    assert!(!text.filled(), "nothing read yet");
    text.update(&[chat("a", 1), chat("b", 1)], &|_| Some(vec![turn("x", "secret words")]));
    assert!(text.filled());
    // Within the timed save's interval: a chat gone is still written out now.
    text.update(&[chat("b", 1)], &|_| None);
    let again = ChatText::new(text.path.clone());
    again.load();
    assert_eq!(again.held().0, 1, "a's text left the saved copy");
    text.update(&[], &|_| None);
    let off = ChatText::new(text.path.clone());
    off.load();
    assert_eq!(off.held(), (0, 0), "chats off: nothing saved");
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn a_damaged_or_oversized_saved_copy_is_left_out() {
    let text = index();
    text.update(&[chat("a", 1)], &|_| Some(vec![turn("x", "kept")]));
    let saved = std::fs::read_to_string(&text.path).expect("saved");
    // A message that starts past its text: that doc is left out, the rest of the copy is read.
    let damaged = saved.replacen("\"start\":0", "\"start\":999", 1);
    std::fs::write(&text.path, damaged).expect("write");
    let again = ChatText::new(text.path.clone());
    again.load();
    assert_eq!(again.held().0, 0);
    // A file past the bound is not read at all.
    let file = std::fs::File::create(&text.path).expect("file");
    file.set_len(SAVED_BYTES + 1).expect("grow");
    let big = ChatText::new(text.path.clone());
    big.load();
    assert_eq!(big.held(), (0, 0));
    let _ = std::fs::remove_file(&text.path);
}

/// A pseudo-random word list (an LCG: the same in every run).
fn words(seed: &mut u64, count: usize, vocabulary: &[String]) -> String {
    let mut out = String::new();
    for _ in 0..count {
        *seed =
            seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        let word = &vocabulary[(*seed >> 33) as usize % vocabulary.len()];
        out.push_str(word);
        out.push(' ');
    }
    out
}

/// The chats page's search over 2,000 chats (dealbreakers D4: a chat appears within 150 ms of the
/// last keystroke). Each keystroke of a few queries runs what `ranked_rows` runs for it: the
/// palette ranker over 2,000 titles, the text search, and the snippets of the rows a page shows.
/// Prints p50, p95 and max. `cargo test -p acpmux --lib chats::text::tests::search_bench --
/// --ignored --nocapture`.
#[test]
#[ignore = "bench: prints p95 search latency over 2,000 chats"]
fn search_bench() {
    const CHATS: usize = 2_000;
    let mut seed = 7_u64;
    let vocabulary: Vec<String> = (0..6_000)
        .map(|i| {
            let len = 2 + i % 9;
            (0..len).map(|j| char::from(b'a' + ((i * 7 + j * 13) % 26) as u8)).collect()
        })
        .collect();
    // About 60 KB of prompts and answers per chat (the mean of a real Claude Code history),
    // so 120 MB in all; one old chat's answer holds the word looked for.
    let turns: Vec<Vec<Turn>> = (0..CHATS)
        .map(|c| {
            (0..30)
                .map(|t| {
                    let mut answer = words(&mut seed, 280, &vocabulary);
                    if c == CHATS - 400 && t == 3 {
                        answer.push_str("the migration fails on zephyrine columns ");
                    }
                    turn(&words(&mut seed, 40, &vocabulary), &answer)
                })
                .collect()
        })
        .collect();
    let chats: Vec<IndexedChat> =
        (0..CHATS).map(|c| chat(&format!("{c:05}"), (CHATS - c) as i64)).collect();
    let text = index();
    let built = Instant::now();
    text.update(&chats, &|entry| {
        let c: usize = entry.session_id.parse().unwrap();
        Some(turns[c].clone())
    });
    let (held, bytes) = text.held();
    println!(
        "chat text bench: {held} chats, {} MB held, filled in {:?}",
        bytes >> 20,
        built.elapsed()
    );
    let titles: Vec<cmux_palette_ranker::Entry> = chats
        .iter()
        .map(|c| {
            crate::chats::window::rank_entry(
                &c.entry.session_id,
                c.entry.title.as_deref(),
                "New chat",
                None,
                "codex",
                None,
            )
        })
        .collect();
    let mut took = Vec::new();
    for query in ["zephyrine", "migration fails", "abc", "the q"] {
        for end in 1..=query.len() {
            let typed = &query[..end];
            let Ok(words) = Needle::parse(typed) else { continue };
            let started = Instant::now();
            let _titled = crate::chats::window::ranked(typed, titles.clone(), None);
            let found = text.search(&words);
            let shown: Vec<Value> =
                found.iter().take(200).filter_map(|(_, hit)| ChatText::hit(hit, &words)).collect();
            took.push(started.elapsed());
            if typed == "zephyrine" {
                assert_eq!(found.len(), 1, "the old chat is found by its word");
                assert!(shown[0]["snippet"].as_str().unwrap().contains("zephyrine"));
            }
        }
    }
    took.sort();
    let at = |p: f64| took[((took.len() as f64 * p).ceil() as usize).saturating_sub(1)];
    println!(
        "chat text bench: {} keystrokes, p50 {:?}, p95 {:?}, max {:?}",
        took.len(),
        at(0.50),
        at(0.95),
        took[took.len() - 1]
    );
    let _ = std::fs::remove_file(&text.path);
}
