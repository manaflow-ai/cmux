use super::StderrTail;

#[test]
fn a_payload_whose_opener_was_cut_off_stays_hidden() {
    let mut tail = StderrTail::default();
    tail.push(b"\x1bP");
    for _ in 0..20 {
        tail.push(&[b'A'; 4096]);
    }
    tail.push(b"secret\x1b\\error: request timed out\n");
    assert_eq!(tail.text(), "error: request timed out");
}

#[test]
fn a_cut_between_esc_and_its_next_byte_reads_the_sequence_whole() {
    let mut tail = StderrTail::default();
    let mut long = vec![b'x'; StderrTail::CAP];
    long.push(0x1b);
    tail.push(&long);
    tail.push(b"]8;;https://x\x07after\nerror: boom\n");
    let text = tail.text();
    assert!(text.ends_with("after\nerror: boom"), "{text:?}");
    assert!(!text.contains("https"), "{text:?}");
}

#[test]
fn an_unfinished_line_keeps_the_text_under_the_cap() {
    let mut tail = StderrTail::default();
    for _ in 0..40 {
        tail.push(&[b'x'; 4095]);
        tail.push(b"\n");
    }
    tail.push(&[b'y'; StderrTail::CAP - 100]);
    let text = tail.text();
    assert!(text.len() <= StderrTail::CAP, "{}", text.len());
    assert!(text.ends_with('y'));
}

#[test]
fn an_endless_line_that_starts_a_control_stays_bounded() {
    let mut tail = StderrTail::default();
    tail.push(b"\x1bP");
    for _ in 0..40 {
        tail.push(&[b'A'; 4096]);
        assert!(tail.pending.len() <= StderrTail::CAP + 4096, "{}", tail.pending.len());
    }
    tail.push(b"\x1b\\error: request timed out\n");
    assert_eq!(tail.text(), "error: request timed out");
}

#[test]
fn the_kept_text_stays_under_the_cap() {
    let mut tail = StderrTail::default();
    for _ in 0..40 {
        tail.push(&[b'x'; 4095]);
        tail.push(b"\n");
    }
    tail.push(b"error: boom\n");
    assert!(tail.text().len() <= StderrTail::CAP);
    assert!(tail.text().ends_with("error: boom"));
}
