//! All chats search per keystroke at 200 and 5,000 chats: the work one keystroke does (row values
//! built, chat texts searched) must not grow with the number of chats (Leo, 2026-11-04: "never
//! ... acceptable ... linear time growth degradation"). Counted, not timed, so it is the same on
//! every machine. `cargo test -p acpmux --lib chats::window::scale_tests -- --nocapture` prints
//! the counts.

use std::path::{Path, PathBuf};

use cmux_chat_index::transcript::Turn;
use cmux_chat_index::{AdapterKind, ChatRoot, RootSource};

use super::*;

const LIMIT: usize = 50;
/// The chats whose text holds the word typed, by position.
fn holds_word(i: usize, chats: usize) -> bool {
    i == 3 || i == chats / 2 || i == chats - 10
}

fn session_id(i: usize) -> String {
    format!("00000000-0000-4000-8000-{i:012}")
}

fn line(i: usize) -> String {
    let (h, m, s) = (i / 3600, i / 60 % 60, i % 60);
    format!(
        r#"{{"type":"user","isSidechain":false,"cwd":"/work/p{}","sessionId":"{}","timestamp":"2026-10-01T{h:02}:{m:02}:{s:02}.000Z","message":{{"role":"user","content":"chat {i} about the build"}}}}"#,
        i % 50,
        session_id(i)
    )
}

fn index_of(home: &Path, chats: usize) -> ChatIndex {
    let projects = home.join("projects");
    for i in 0..chats {
        let file: PathBuf =
            projects.join(format!("-work-p{}", i % 50)).join(format!("{}.jsonl", session_id(i)));
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{}\n", line(i))).unwrap();
    }
    let mut index = ChatIndex::new(vec![ChatRoot {
        harness: AdapterKind::ClaudeCode,
        path: projects.clone(),
        real_path: projects.canonicalize().unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    }]);
    index.rescan_all();
    assert_eq!(index.chats().len(), chats);
    index
}

fn text_of(home: &Path, index: &ChatIndex, chats: usize) -> ChatText {
    let text = ChatText::new(home.join("text.json"));
    let held: Vec<IndexedChat> = index.chats().into_iter().cloned().collect();
    text.update(&held, &|entry| {
        let i: usize = entry.session_id.rsplit('-').next()?.parse().ok()?;
        let answer = if holds_word(i, chats) {
            "the zephyrine migration failed on two columns".to_owned()
        } else {
            format!("we talked about the build in chat {i}")
        };
        Some(vec![Turn {
            prompt: "what happened".into(),
            answer,
            prompt_at: None,
            answer_at: None,
        }])
    });
    text
}

type Costs = Vec<(usize, usize, Vec<String>)>;

/// What each keystroke of `typed` cost (row values built, chat texts searched, its rows), and the
/// keys of the chats whose text holds the word, in the index's order.
fn keystrokes(chats: usize, typed: &str) -> (Costs, Vec<String>) {
    let home = tempfile::tempdir().unwrap();
    let index = index_of(home.path(), chats);
    let text = text_of(home.path(), &index, chats);
    let holders = index
        .chats()
        .into_iter()
        .map(|chat| key_text(&chat.entry.key()))
        .filter(|key| {
            key.rsplit('-')
                .next()
                .and_then(|n| n.parse().ok())
                .is_some_and(|i| holds_word(i, chats))
        })
        .collect();
    let activity = ChatActivity::default();
    let costs = (1..=typed.len())
        .map(|end| {
            let spec = WindowSpec::from_params(&json!({"window": "all", "query": &typed[..end],
                "limit": LIMIT, "content": true, "untitled": "New chat"}))
            .unwrap();
            let (values, scanned) = (values_built(), text.scanned());
            let window = rows(&spec, &index, &activity, Some(&text));
            let keys = window.rows.into_iter().map(|(key, _)| key).collect();
            (values_built() - values, text.scanned() - scanned, keys)
        })
        .collect();
    (costs, holders)
}

/// A title query that every chat passes builds values for the rows it shows, not for every chat.
#[test]
fn a_title_query_builds_values_for_the_page_only_at_200_and_5000_chats() {
    let runs: Vec<(usize, Costs)> =
        [200, 5_000].into_iter().map(|chats| (chats, keystrokes(chats, "build").0)).collect();
    for (chats, costs) in &runs {
        let values: Vec<usize> = costs.iter().map(|(v, _, _)| *v).collect();
        println!(
            "all chats search, title query, {chats} chats: values built per keystroke {values:?}"
        );
    }
    for (chats, costs) in &runs {
        let (_, _, keys) = costs.last().unwrap();
        assert_eq!(keys.len(), LIMIT, "a full page");
        for (n, (values, _, _)) in costs.iter().enumerate() {
            assert!(
                *values <= LIMIT,
                "keystroke {} over {chats} chats built {values} row values; a page shows {LIMIT}",
                n + 1
            );
        }
    }
}

/// Typing a word said in three chats: each keystroke after the first searches only the chats the
/// one before found, and builds values only for the rows it shows.
#[test]
fn typing_a_said_word_searches_only_the_last_hits_at_200_and_5000_chats() {
    let runs: Vec<(usize, (Costs, Vec<String>))> =
        [200, 5_000].into_iter().map(|chats| (chats, keystrokes(chats, "zephyrine"))).collect();
    for (chats, (costs, _)) in &runs {
        let values: Vec<usize> = costs.iter().map(|(v, _, _)| *v).collect();
        let scanned: Vec<usize> = costs.iter().map(|(_, s, _)| *s).collect();
        let shown: Vec<usize> = costs.iter().map(|(_, _, keys)| keys.len()).collect();
        println!(
            "all chats search, said word, {chats} chats: values built per keystroke {values:?}, \
             chat texts searched per keystroke {scanned:?}, rows {shown:?}"
        );
    }
    for (chats, (costs, holders)) in &runs {
        let (_, _, keys) = costs.last().unwrap();
        assert_eq!(holders.len(), 3);
        assert_eq!(keys, holders, "the three chats, in the index's order (newest first)");
        for (n, (values, scanned, _)) in costs.iter().enumerate() {
            assert!(*values <= LIMIT, "keystroke {} built {values} row values", n + 1);
            if n > 0 {
                let before = costs[n - 1].2.len();
                assert!(
                    *scanned <= before,
                    "keystroke {} over {chats} chats searched {scanned} chat texts; the one \
                     before found {before}",
                    n + 1
                );
            }
        }
    }
}
