use std::cell::{Cell, RefCell};
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

/// A newest message past the bound alone (a pasted 50 MB log) keeps its newest text: the chat
/// was held with no text at all, so no word of it was found (`text_scale_bench`).
#[test]
fn a_message_past_the_bound_alone_keeps_its_newest_text() {
    let words = needle("tailword");
    // Two-byte characters, so the cut falls inside one.
    let huge = format!("headword {} tailword", "é".repeat(CHAT_BYTES));
    let stamp = Stamp { updated_ms: 0, messages: None };
    let read = Doc::new(stamp, &[turn("start", "short"), turn("paste", &huge)]);
    let mut edited = Doc::new(stamp, &[turn("start", "short")]);
    edited.edit(1, &[turn("paste", &huge)], 0);
    for doc in [read, edited] {
        assert!(doc.is_sound(), "{} bytes", doc.text.len());
        let found = doc.find(&words, &Matcher::new(&words)).expect("the newest text is found");
        assert_eq!(doc.messages[found.message as usize].turn, 1);
        assert!(doc.find(&needle("headword"), &Matcher::new(&needle("headword"))).is_none());
    }
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
fn a_stamp_only_change_does_not_rewrite_the_saved_text() {
    let text = index();
    let turns = vec![turn("x", "same searchable content")];
    text.update(&[chat("a", 1)], &|_| Some(turns.clone()));
    let saved = text.saves();

    // The chat index stamp moved, but the transcript content did not.
    text.update(&[chat("a", 2)], &|_| Some(turns.clone()));
    assert_eq!(text.saves(), saved, "a metadata-only stamp update rewrote the text index");
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

/// Leo's history holds more text than the bound, so every pass runs at it: the newest chat grows
/// and the oldest held chat is let go of. Before, each such pass rewrote the whole saved copy (up
/// to 128 MB, every pass the text thread ran) and read the first chat past the bound again only to
/// let it go. Now a pass at the bound writes nothing until the timed save and reads only the chat
/// that changed; a chat gone from the chat index still leaves the saved copy at once.
#[test]
fn at_the_bound_a_pass_writes_nothing_and_reads_only_what_changed() {
    const OLDER: usize = 60;
    const PASSES: i64 = 300;
    let path = std::env::temp_dir().join(format!("acpmux-text-{}.json", uuid::Uuid::now_v7()));
    let text = ChatText::with_total(path, 40 * 1024);
    let reads = Cell::new(0_usize);
    // The newest chat has as many turns as its time says (~20 bytes each); every older chat has
    // ten (~1.2 KB).
    let read = |entry: &ChatEntry| {
        reads.set(reads.get() + 1);
        let (turns, answer) = if entry.session_id == "new" {
            (entry.updated_ms, "ok".to_owned())
        } else {
            (10, "answer ".repeat(14))
        };
        Some(
            (0..turns)
                .map(|t| turn(&format!("prompt {t} of {}", entry.session_id), &answer))
                .collect(),
        )
    };
    let older: Vec<IndexedChat> = (0..OLDER).map(|c| chat(&format!("c{c:02}"), 1)).collect();
    let list = |turns: i64| {
        let mut chats = vec![chat("new", turns)];
        chats.extend(older.iter().cloned());
        chats
    };
    text.update(&list(10), &read);
    let (_, held) = text.held();
    assert!(held <= 40 * 1024 && held > 30 * 1024, "the first fill holds up to the bound: {held}");
    let first = (text.saves(), reads.get());
    let held_at_first = text.held().0;
    for turns in 11..10 + PASSES {
        text.update(&list(turns), &read);
    }
    let (chats, bytes) = text.held();
    assert!(bytes <= 40 * 1024, "the bound holds: {bytes}");
    assert!(chats < held_at_first, "the newest chat grew, so older chats were let go of");
    assert_eq!(
        text.saves(),
        first.0,
        "no pass at the bound rewrote the saved copy ({} bytes written by the first)",
        first.0.1
    );
    assert_eq!(
        reads.get() - first.1,
        usize::try_from(PASSES - 1).unwrap(),
        "each pass read only the chat that changed, not the chat past the bound"
    );
    // Newest first: the newest chats are found, the oldest let go of are not.
    assert!(text.search(&needle("prompt of new")).contains_key("codex:new"));
    assert!(text.search(&needle("prompt of c00")).contains_key("codex:c00"));
    assert!(text.search(&needle("prompt of c59")).is_empty());
    let every = text.search(&needle("prompt of")).len();
    assert_eq!(every, chats, "every held chat and only those");
    // A chat gone leaves the saved copy at once, within the timed save's interval.
    let mut without_c00 = list(10 + PASSES);
    without_c00.remove(1);
    text.update(&without_c00, &read);
    assert_eq!(text.saves().0, first.0.0 + 1, "a chat gone is written out now");
    let again = ChatText::new(text.path.clone());
    again.load();
    assert!(again.search(&needle("prompt of c00")).is_empty(), "c00's text left the saved copy");
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

/// A save under the held home is whole or not there: its copy is written and synced beside the
/// file, then renamed over it in the same folder. Interrupted between the two (the process ends
/// at `config::seams::on_before_rename`), the old copy is still there, whole.
#[test]
fn a_held_save_interrupted_before_its_rename_leaves_the_old_copy() {
    crate::lost_home_race_tests::isolated(
        module_path!(),
        "a_held_save_interrupted_before_its_rename_leaves_the_old_copy",
        |home| {
            let path = home.join("chat-index").join("text-v1.json");
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, "old").unwrap();
            crate::config::hold_home();
            let _hold = crate::config::seams::on_before_rename(|_| {
                println!("held-before-rename");
                std::process::exit(0);
            });
            let text = ChatText::new(path);
            text.update(&[chat("a", 1)], &|_| Some(vec![turn("x", "new words")]));
        },
        |home, stdout| {
            assert!(
                stdout.contains("held-before-rename"),
                "the save never stopped at a synced copy before its rename: {stdout}"
            );
            let kept = std::fs::read_to_string(home.join("chat-index").join("text-v1.json"));
            assert_eq!(kept.unwrap(), "old", "an interrupted save changed the old copy");
        },
    );
}

/// Past [`PAR_MIN_BYTES`] a pass is split across cores; the answer is the one a single thread
/// gives, every hit and its newest message, at any split.
#[test]
fn a_pass_split_across_cores_finds_what_one_thread_finds() {
    let line = "lorem ipsum dolor sit amet ".repeat(400);
    let docs: Vec<(String, Arc<Doc>)> = (0..400)
        .map(|i| {
            let said =
                if i % 37 == 0 { format!("{line} the deploy failed {i}") } else { line.clone() };
            let doc = Doc::new(Stamp { updated_ms: i, messages: None }, &[turn("x", &said)]);
            (format!("codex:{i}"), Arc::new(doc))
        })
        .collect();
    let bytes: usize = docs.iter().map(|(_, doc)| doc.text.len()).sum();
    assert!(bytes > PAR_MIN_BYTES, "{bytes} bytes: the split path");
    let words = needle("DEPLOY fail");
    let matcher = Matcher::new(&words);
    let search = |key: &String, doc: &Arc<Doc>| {
        let matched = doc.find(&words, &matcher)?;
        Some((key.clone(), Found { doc: doc.clone(), matched }))
    };
    let one: HashMap<String, Found> =
        docs.iter().filter_map(|(key, doc)| search(key, doc)).collect();
    let refs: Vec<(&String, &Arc<Doc>)> = docs.iter().map(|(key, doc)| (key, doc)).collect();
    let split: HashMap<String, Found> =
        par_filter_map(&refs, |&(key, doc)| search(key, doc)).into_iter().collect();
    let mut keys: Vec<&String> = split.keys().collect();
    keys.sort();
    let mut want: Vec<&String> = one.keys().collect();
    want.sort();
    assert_eq!(keys, want);
    assert_eq!(keys.len(), 11);
    for (key, found) in &split {
        assert_eq!(found.matched, one[key].matched);
    }
    // Under the bound, or one chat: one thread, the same answer.
    assert_eq!(par_filter_map(&refs[..1], |&(key, doc)| search(key, doc)).len(), 1);
}

#[test]
fn a_pass_over_much_text_on_many_threads_finds_what_one_thread_finds() {
    // Past PAR_MIN_BYTES so the pass takes threads; docs of uneven size so chunks finish apart.
    let filler = "lorem ipsum dolor sit amet ".repeat(1_000);
    let docs: Vec<(String, Arc<Doc>)> = (0..400)
        .map(|n| {
            let mut turns = vec![turn("start", &filler[..(n % 7 + 1) * 3_000])];
            if n % 13 == 0 {
                turns.push(turn("needle here", &format!("planted Zebrafinch {n}")));
            }
            turns.push(turn("end", &filler[..(n % 5 + 1) * 2_000]));
            (
                format!("chat-{n}"),
                Arc::new(Doc::new(Stamp { updated_ms: 0, messages: None }, &turns)),
            )
        })
        .collect();
    let refs: Vec<(&String, &Arc<Doc>)> = docs.iter().map(|(k, d)| (k, d)).collect();
    let bytes: usize = refs.iter().map(|(_, d)| d.text.len()).sum();
    assert!(bytes >= PAR_MIN_BYTES, "{bytes} bytes take one thread");
    let words = needle("zebrafinch planted");
    let matcher = Matcher::new(&words);
    let find =
        |&(key, doc): &(&String, &Arc<Doc>)| doc.find(&words, &matcher).map(|m| (key.clone(), m));
    let mut many = par_filter_map(&refs, find);
    let mut one: Vec<_> = refs.iter().filter_map(find).collect();
    many.sort_by(|a, b| a.0.cmp(&b.0));
    one.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(many.len(), 400_usize.div_ceil(13));
    assert_eq!(many, one);
    // Below the bound the pass stays on this thread and still finds every doc.
    assert_eq!(par_filter_map(&refs[..26], find).len(), 2);
}

#[test]
fn the_trigram_set_never_drops_a_hit_and_a_word_no_chat_says_reads_no_text() {
    let mut seed = 11_u64;
    let vocabulary: Vec<String> = (0..400)
        .map(|i| {
            let len = 2 + i % 9;
            (0..len).map(|j| char::from(b'a' + ((i * 7 + j * 3) % 26) as u8)).collect::<String>()
        })
        .collect();
    let chats: Vec<IndexedChat> = (0..60).map(|n| chat(&format!("c{n}"), n)).collect();
    // Uneven sizes, mixed case: a short chat, and long ones past the set's most bits.
    let said: HashMap<String, Vec<Turn>> = (0..60)
        .map(|n| {
            let mut s = seed.wrapping_add(n as u64);
            let count = [5, 60, 2_000, 30_000][n % 4];
            let mut text = words(&mut s, count, &vocabulary);
            if n % 3 == 0 {
                text = text.to_uppercase();
            }
            (format!("c{n}"), vec![turn("q", &text)])
        })
        .collect();
    let text = index();
    text.update(&chats, &|entry| said.get(&entry.session_id).cloned());
    let plain = |query: &str| {
        let words = needle(query);
        let unfiltered = Matcher { trigrams: Vec::new(), ..Matcher::new(&words) };
        let mut keys: Vec<String> = lock(&text.inner)
            .docs
            .iter()
            .filter(|(_, doc)| doc.find(&words, &unfiltered).is_some())
            .map(|(key, _)| key.clone())
            .collect();
        keys.sort();
        keys
    };
    for _ in 0..300 {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
        let a = &vocabulary[(seed >> 33) as usize % vocabulary.len()];
        let b = &vocabulary[(seed >> 13) as usize % vocabulary.len()];
        // A word, two words, and a piece of a word across a word's end.
        for query in [a.clone(), format!("{a} {b}"), format!("{} {}", &a[1..], &b[..2])] {
            let mut found: Vec<String> = text.search(&needle(&query)).keys().cloned().collect();
            found.sort();
            assert_eq!(found, plain(&query), "{query}");
        }
    }
    let (scanned, read) = (text.scanned(), text.read());
    assert!(text.search(&needle("zqxjvw")).is_empty());
    assert_eq!(text.scanned() - scanned, 60, "every chat is asked");
    assert_eq!(text.read() - read, 0, "no chat's text is read for a word none says");
    let _ = std::fs::remove_file(&text.path);
}

#[test]
fn an_edited_doc_keeps_finding_old_and_added_words_through_its_trigram_set() {
    let stamp = Stamp { updated_ms: 0, messages: None };
    let mut doc = Doc::new(stamp, &[turn("first", "Alpha")]);
    // Grow past the set's first size, so it is read again off the whole text.
    let long = "filler words here ".repeat(200);
    doc.edit(1, &[turn(&long, "Bravo"), turn("x", "charlie")], 0);
    for word in ["alpha", "BRAVO", "Charlie", "filler"] {
        let words = needle(word);
        assert!(doc.find(&words, &Matcher::new(&words)).is_some(), "{word}");
    }
    let words = needle("zqxjvw");
    assert!(!doc.may_hold(&Matcher::new(&words)));
}
