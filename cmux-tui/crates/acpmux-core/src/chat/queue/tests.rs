use super::*;
use crate::chat::source::{self, Chunk, Piece};
use acpmux_book::translate::prompt_hash;

/// One raw line at place 0, read only through `read_at`; it counts what each read returned.
struct Line {
    bytes: Vec<u8>,
    reads: Vec<usize>,
}

impl Line {
    fn new(bytes: Vec<u8>) -> Self {
        Self { bytes, reads: Vec::new() }
    }

    fn read(&self) -> usize {
        self.reads.iter().sum()
    }
}

impl RawSource for Line {
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        Ok(Chunk::with_stamp(Vec::new(), place, source::byte_places, true, 0, 1))
    }
    fn holds(&mut self, _place: u64) -> io::Result<bool> {
        Ok(true)
    }
    fn hint(&self) -> io::Result<u64> {
        Ok(0)
    }
    fn sync_through(&mut self, _place: u64) -> io::Result<()> {
        Ok(())
    }
    fn identity(&self) -> &[u8] {
        b"line"
    }
    fn stamp(&self) -> u64 {
        1
    }
    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> io::Result<Piece> {
        let at = usize::try_from(place + offset).unwrap_or(usize::MAX).min(self.bytes.len());
        let end = at.saturating_add(max).min(self.bytes.len());
        let mut bytes = self.bytes.get(at..end).unwrap_or_default().to_vec();
        let ends = match bytes.iter().position(|byte| *byte == b'\n') {
            Some(newline) => {
                bytes.truncate(newline + 1);
                true
            }
            None => end == self.bytes.len(),
        };
        self.reads.push(bytes.len());
        Ok(Piece { bytes, ends })
    }
}

/// A v1 `queued` line for `text`, with other members before it, and its entry.
fn queued(id: &str, text: &str) -> (Line, QueueEntry) {
    let msg = serde_json::json!({"kind": "mux", "event": "queued",
        "msg": {"client": "c", "promptId": id, "turnId": "t", "text": text, "position": 1}});
    let mut bytes = serde_json::to_vec(&msg).unwrap();
    bytes.push(b'\n');
    let entry =
        QueueEntry::new(prompt_hash(id), 42, false, 0, bytes.len() as u64, text.len() as u64);
    (Line::new(bytes), entry)
}

#[test]
fn a_head_is_one_bounded_read_with_at_most_a_kilobyte_of_escaped_text() {
    let text = "\"q\"\n".repeat(2_000);
    let (mut line, entry) = queued("p-1", &text);
    let item = head(&mut line, &entry).unwrap();
    assert_eq!(item.id, "p-1");
    assert_eq!(item.len, text.len() as u64);
    assert_eq!(item.at, 42);
    assert!(!item.held);
    assert!(text.starts_with(&item.text));
    assert!(serde_json::to_string(&item.text).unwrap().len() <= HEAD_TEXT + 2);
    assert_eq!(line.reads.len(), 1);
    assert!(line.read() <= HEAD_READ);
}

#[test]
fn a_text_that_begins_past_the_head_read_gives_an_empty_head_and_its_length() {
    let msg =
        serde_json::json!({"msg": {"pad": "x".repeat(HEAD_READ), "promptId": "p", "text": "late"}});
    let bytes = serde_json::to_vec(&msg).unwrap();
    let entry = QueueEntry::new(prompt_hash("p"), 1, true, 0, bytes.len() as u64, 4);
    let mut line = Line::new(bytes);
    let item = head(&mut line, &entry).unwrap();
    assert_eq!(item.text, "");
    assert_eq!(item.len, 4);
    assert!(item.held);
    assert_eq!(read_prompt(&mut line, &entry, None, 4, None).unwrap(), Err(PromptError::NoText));
}

#[test]
fn tokens_are_32_hex_digits_and_nothing_else() {
    let token = Token { text: 7, line: u64::MAX };
    assert_eq!(token.encode().len(), 32);
    assert_eq!(Token::decode(&token.encode()), Some(token));
    assert_eq!(Token::decode("0"), None);
    assert_eq!(Token::decode(&"g".repeat(32)), None);
    assert_eq!(Token::decode(&"é".repeat(16)), None);
}

#[test]
fn escapes_and_surrogate_pairs_decode_across_reads() {
    let text = "a\"b\\c\n\u{1}é🙂".repeat(5_000);
    let (mut line, entry) = queued("p", &text);
    let mut got = Vec::new();
    let mut from = None;
    let mut start = None;
    loop {
        let read = read_prompt(&mut line, &entry, start, 3_000, from).unwrap().unwrap();
        assert_eq!(read.start, got.len() as u64);
        got.extend_from_slice(&read.bytes);
        match read.next {
            Some(next) => {
                start = Some(next.text);
                from = Some(next);
            }
            None => break,
        }
    }
    assert_eq!(String::from_utf8(got).unwrap(), text);
}

#[test]
fn escaped_surrogate_pairs_go_out_whole_a_byte_a_request() {
    let bytes = br#"{"msg":{"promptId":"s","text":"\ud83d\ude42\u00e9\ud800x"}}"#.to_vec();
    let decoded = "🙂é\u{fffd}x";
    let entry =
        QueueEntry::new(prompt_hash("s"), 1, false, 0, bytes.len() as u64, decoded.len() as u64);
    let mut line = Line::new(bytes);
    let mut got = Vec::new();
    let mut from = None;
    let mut start = Some(0);
    loop {
        let read = read_prompt(&mut line, &entry, start, 1, from).unwrap().unwrap();
        got.extend_from_slice(&read.bytes);
        match read.next {
            Some(next) => {
                start = Some(next.text);
                from = Some(next);
            }
            None => break,
        }
    }
    assert_eq!(String::from_utf8(got).unwrap(), decoded);
}

#[test]
fn a_five_mebibyte_prompt_reads_by_tokens_and_each_request_scans_at_most_a_mebibyte() {
    let text = "x".repeat(5 << 20);
    let (mut line, entry) = queued("big", &text);
    let mut from = None;
    let mut start = Some(0);
    let mut total = 0u64;
    let mut requests = 0;
    loop {
        let before = line.read();
        let read =
            read_prompt(&mut line, &entry, start, MAX_PAGE_BYTES as u64, from).unwrap().unwrap();
        requests += 1;
        assert!(read.scanned <= SCAN_LIMIT);
        assert!((line.read() - before) as u64 <= SCAN_LIMIT + HEAD_READ as u64);
        assert!(read.bytes.iter().all(|byte| *byte == b'x'));
        total += read.bytes.len() as u64;
        match read.next {
            Some(next) => {
                start = Some(next.text);
                from = Some(next);
            }
            None => break,
        }
    }
    assert_eq!(total, 5 << 20);
    assert_eq!(requests, (5 << 20) / MAX_PAGE_BYTES);
}

#[test]
fn an_offset_without_a_token_stops_at_a_mebibyte_and_names_where_it_stopped() {
    let text = "y".repeat(3 << 20);
    let (mut line, entry) = queued("far", &text);
    let read = read_prompt(&mut line, &entry, Some(2 << 20), 10, None).unwrap().unwrap();
    assert!(read.bytes.is_empty());
    assert_eq!(read.scanned, SCAN_LIMIT);
    let next = read.next.unwrap();
    assert!(next.text > 0 && next.text < 2 << 20);
    assert!(line.read() as u64 <= SCAN_LIMIT + HEAD_READ as u64);
    // Going on from its token reaches the offset, a mebibyte a request.
    let read = read_prompt(&mut line, &entry, Some(2 << 20), 10, Some(next)).unwrap().unwrap();
    assert!(read.next.is_some());
}

#[test]
fn a_token_outside_the_line_or_behind_the_range_is_refused() {
    let (mut line, entry) = queued("p", "hello");
    let outside = Token { text: 0, line: u64::from(entry.span) };
    assert_eq!(
        read_prompt(&mut line, &entry, None, 5, Some(outside)).unwrap(),
        Err(PromptError::TokenOutside)
    );
    let first = read_prompt(&mut line, &entry, Some(0), 2, None).unwrap().unwrap();
    assert_eq!(first.bytes, b"he");
    let next = first.next.unwrap();
    assert_eq!(
        read_prompt(&mut line, &entry, Some(0), 2, Some(next)).unwrap(),
        Err(PromptError::BeforeToken)
    );
    let rest = read_prompt(&mut line, &entry, None, 10, Some(next)).unwrap().unwrap();
    assert_eq!(rest.bytes, b"llo");
    assert_eq!(rest.next, None);
}

#[test]
fn a_line_cut_inside_its_text_is_truncated() {
    let (line, entry) = queued("p", &"z".repeat(100));
    let cut = line.bytes.len() - 40;
    let mut line = Line::new(line.bytes.get(..cut).unwrap().to_vec());
    assert_eq!(
        read_prompt(&mut line, &entry, Some(0), 100, None).unwrap(),
        Err(PromptError::Truncated)
    );
}

#[test]
fn find_string_walks_members_and_skips_nested_values() {
    let line = br#"{"a":{"text":"no"},"b":[1,"x\"y",{"c":2}],"msg":{"n":null,"text":"yes"}}"#;
    let at = find_string(line, &[b"msg", b"text"]).unwrap();
    assert_eq!(line.get(at..at + 3), Some(&b"yes"[..]));
    assert_eq!(find_string(line, &[b"msg", b"promptId"]), None);
    assert_eq!(find_string(&line[..20], &[b"msg", b"text"]), None);
}

#[test]
fn a_raw_body_s_text_is_read_in_pieces_with_escapes_cut_anywhere_and_nothing_past_it() {
    // Text all of two-byte escapes, behind prefixes of each parity: some piece ends between an
    // escape's backslash and the byte it escapes.
    for prefix in 0..4 {
        let text = format!("{}{}", "p".repeat(prefix), "\\\"🙂é".repeat(400 * 1024 / 8));
        let msg = serde_json::json!({"kind": "mux", "event": "user_message",
            "msg": {"promptId": "p", "text": text, "trailer": "z".repeat(4 << 20)}});
        let mut bytes = serde_json::to_vec(&msg).unwrap();
        bytes.push(b'\n');
        let escaped = serde_json::to_vec(&text).unwrap();
        let mut line = Line::new(bytes);
        let Some(read) = read_text(&mut line, 0).unwrap() else { panic!("no text in the head") };
        assert!(read == escaped, "prefix {prefix}: the text read is not the line's");
        let decoded: String = serde_json::from_slice(&read).unwrap();
        assert_eq!(decoded, text);
        assert!(
            line.read() <= HEAD_READ + escaped.len() + TEXT_READ,
            "prefix {prefix}: {} bytes read for {} of text; the 4 MiB after it are not read",
            line.read(),
            escaped.len()
        );
    }
}

#[test]
fn a_raw_body_s_text_past_the_head_or_cut_off_is_none_or_refused() {
    // `json!` writes keys in order: `head` comes before `msg`.
    let late = serde_json::json!({"kind": "mux", "head": "q".repeat(2 * HEAD_READ),
        "msg": {"text": "late"}});
    let mut line = Line::new(serde_json::to_vec(&late).unwrap());
    assert_eq!(read_text(&mut line, 0).unwrap(), None);
    let mut cut = Line::new(br#"{"kind":"mux","msg":{"text":"never closed"#.to_vec());
    assert_eq!(read_text(&mut cut, 0).unwrap_err().kind(), io::ErrorKind::InvalidData);
}
