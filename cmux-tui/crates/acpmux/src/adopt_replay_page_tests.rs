use super::*;
use serde_json::json;
use std::io::Write;

fn scratch(name: &str) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-claude-page-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("s.jsonl")
}

fn prompt(n: usize) -> String {
    json!({"type": "user", "timestamp": "2026-10-29T10:00:00.000Z",
        "message": {"role": "user", "content": format!("prompt {n}")}})
    .to_string()
}

fn answer(n: usize) -> String {
    json!({"type": "assistant", "timestamp": "2026-10-29T10:00:01.000Z",
        "message": {"role": "assistant", "stop_reason": "end_turn",
            "content": [{"type": "text", "text": format!("answer {n}")}]}})
    .to_string()
}

/// `turns` turns, each a prompt, a progress line of `pad` bytes and an answer.
fn transcript(file: &Path, turns: usize, pad: usize) {
    let mut f = std::io::BufWriter::new(File::create(file).unwrap());
    let filler = "x".repeat(pad);
    for n in 0..turns {
        writeln!(f, "{}", prompt(n)).unwrap();
        writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
        writeln!(f, "{}", answer(n)).unwrap();
    }
}

fn prompts(page: &ClaudePage) -> Vec<String> {
    page.turns.iter().map(|t| t.prompt.clone()).collect()
}

#[test]
fn a_page_is_the_newest_turns_and_paging_back_reads_each_once() {
    let file = scratch("paging");
    transcript(&file, 70, 10);
    let page = claude_page(&file, None, 30);
    let want: Vec<String> = (40..70).map(|n| format!("prompt {n}")).collect();
    assert_eq!(prompts(&page), want);
    assert_eq!(page.turns[29].answer, "answer 69");
    assert!(page.start > 0);
    let mut all = prompts(&page);
    let mut end = page.start;
    while end > 0 {
        let older = claude_page(&file, Some(end), 30);
        assert!(older.start < end, "a page moves back");
        let mut got = prompts(&older);
        got.extend(all);
        all = got;
        end = older.start;
    }
    let every: Vec<String> = (0..70).map(|n| format!("prompt {n}")).collect();
    assert_eq!(all, every);
}

#[test]
fn a_page_of_a_big_transcript_reads_only_its_tail() {
    let file = scratch("big");
    // 600 turns of 100 KiB: about 60 MB.
    transcript(&file, 600, 100 << 10);
    let len = std::fs::metadata(&file).unwrap().len();
    let page = claude_page(&file, None, PAGE_TURNS);
    assert_eq!(page.turns.last().unwrap().prompt, "prompt 599");
    assert!(page.read <= PAGE_BYTES + CHUNK, "read {} of {len}", page.read);
    assert!(page.start > len - PAGE_BYTES - CHUNK);
    // Every turn of the page is whole: it starts at a prompt.
    assert!(page.turns.iter().all(|t| t.prompt.starts_with("prompt ")));
}

#[test]
fn a_line_still_being_written_waits() {
    let file = scratch("partial");
    transcript(&file, 3, 4);
    let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    write!(f, "{}", &prompt(3)[..20]).unwrap();
    let page = claude_page(&file, None, 30);
    assert_eq!(prompts(&page), ["prompt 0", "prompt 1", "prompt 2"]);
    assert_eq!(page.start, 0);
}

#[test]
fn a_turn_bigger_than_a_page_shows_its_newest_part() {
    let file = scratch("one-turn");
    let mut f = std::io::BufWriter::new(File::create(&file).unwrap());
    writeln!(f, "{}", prompt(0)).unwrap();
    let filler = "y".repeat(1 << 20);
    for _ in 0..20 {
        writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
    }
    writeln!(f, "{}", answer(0)).unwrap();
    drop(f);
    let page = claude_page(&file, None, 30);
    assert!(page.read <= PAGE_MAX_BYTES + CHUNK, "read {}", page.read);
    assert!(page.start > 0);
    assert_eq!(page.turns.len(), 1);
    assert_eq!(page.turns[0].prompt, "");
    assert_eq!(page.turns[0].answer, "answer 0");
    // The older page holds the prompt.
    let older = claude_page(&file, Some(page.start), 30);
    assert_eq!(prompts(&older), ["prompt 0"]);
}

#[test]
fn a_turn_bigger_than_a_page_is_followed_from_its_prompt() {
    let file = scratch("one-turn-watch");
    let mut f = std::io::BufWriter::new(File::create(&file).unwrap());
    writeln!(f, "{}", prompt(0)).unwrap();
    writeln!(f, "{}", answer(0)).unwrap();
    let at = f.get_ref().metadata().unwrap().len() + f.buffer().len() as u64;
    writeln!(f, "{}", prompt(1)).unwrap();
    let filler = "y".repeat(1 << 20);
    for _ in 0..20 {
        writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
    }
    writeln!(f, "{}", answer(1)).unwrap();
    drop(f);
    // The newest page has no prompt; the one before it starts at prompt 1.
    assert!(claude_page(&file, None, 1).turns[0].prompt.is_empty());
    assert_eq!(newest_prompt_start(&file, 1), Some(at));
}

/// One complete line bigger than a page, after turns: each page moves back, and the newest
/// page with turns is the one before it.
#[test]
fn a_line_bigger_than_a_page_is_paged_past() {
    let file = scratch("big-line");
    transcript(&file, 5, 4);
    let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    writeln!(f, "{}", json!({"type": "progress", "data": "z".repeat(20 << 20)})).unwrap();
    drop(f);
    let len = std::fs::metadata(&file).unwrap().len();
    let page = claude_page(&file, None, 30);
    assert!(page.turns.is_empty());
    assert!(page.start < len, "a page moves back: {} of {len}", page.start);
    assert!(page.read <= PAGE_MAX_BYTES + CHUNK, "read {}", page.read);
    let newest = newest_claude_page(&file, 30);
    let want: Vec<String> = (0..5).map(|n| format!("prompt {n}")).collect();
    assert_eq!(prompts(&newest), want);
    assert_eq!(newest.start, 0);
}

/// A last line still being written that is bigger than a page: the page stays within its cap.
#[test]
fn an_unfinished_line_bigger_than_a_page_keeps_the_cap() {
    let file = scratch("big-partial");
    transcript(&file, 5, 4);
    let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
    write!(f, "{{\"type\":\"progress\",\"data\":\"{}", "z".repeat(20 << 20)).unwrap();
    drop(f);
    let len = std::fs::metadata(&file).unwrap().len();
    let page = claude_page(&file, None, 30);
    assert!(page.read <= PAGE_MAX_BYTES + CHUNK, "read {}", page.read);
    assert!(page.start < len);
    assert_eq!(prompts(&newest_claude_page(&file, 30)).len(), 5);
}

#[test]
fn an_unreadable_file_is_an_empty_page() {
    let page = claude_page(Path::new("/nonexistent/acpmux/s.jsonl"), None, 30);
    assert_eq!(page, ClaudePage::default());
}
