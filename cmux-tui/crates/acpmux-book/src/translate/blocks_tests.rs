use super::{Block, Event};
fn events(s: &str) -> Vec<Event> {
    let mut b = Block::default();
    s.chars().map(|c| b.push(c)).collect()
}

#[test]
fn first_byte_after_blank_decides_without_lookahead() {
    let e = events("one\n\nnext");
    assert!(matches!(e[5], Event::BeforeLine));
    assert!(!events("one\n\n-x").iter().any(|e| matches!(e, Event::BeforeLine)));
    assert!(!events("one\n\n1986").iter().any(|e| matches!(e, Event::BeforeLine)));
}
#[test]
fn spaces_tabs_and_cr_are_blank_or_indent() {
    assert!(events("one\n \t\r\nnext").iter().any(|e| matches!(e, Event::BeforeLine)));
    assert!(!events("one\n\n\tnext").iter().any(|e| matches!(e, Event::BeforeLine)));
    let mut b = Block::default();
    for c in "one\n\n`".chars() {
        let _ = b.push(c);
    }
    assert_eq!(b.line_bytes(), 1);
}
#[test]
fn tab_is_four_columns_and_marker_run_ends_on_space_or_text() {
    assert!(!events("one\n\n\ttext").iter().any(|e| matches!(e, Event::BeforeLine)));
    let mut b = Block::default();
    for c in "```\n``` x\n".chars() {
        let _ = b.push(c);
    }
    assert_eq!(b.fence_marker().as_deref(), Some("```"));
}
#[test]
fn fences_suppress_blank_boundary_and_reject_nonmatching_close() {
    let mut b = Block::default();
    for c in "```rust\n\ninside\n\n```  x\n\n".chars() {
        let _ = b.push(c);
    }
    assert_eq!(b.fence_marker().as_deref(), Some("```"));
    for c in "```\n\n".chars() {
        let _ = b.push(c);
    }
    assert_eq!(b.fence_marker(), None);
}
#[test]
fn cut_inside_line_resets_segment_counter_not_fence_state() {
    let mut b = Block::default();
    for c in "```\nbody".chars() {
        let _ = b.push(c);
    }
    b.mark_cut_inside_line();
    assert_eq!(b.line_bytes(), 0);
    assert_eq!(b.fence_marker().as_deref(), Some("```"));
    assert!(b.take_cut_inside_line());
}
