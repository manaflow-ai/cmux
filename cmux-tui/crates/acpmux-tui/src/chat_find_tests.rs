use super::*;

fn rows(lines: &[&str]) -> Vec<String> {
    lines.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn finds_every_match_folded_like_the_gui() {
    let r = rows(&["› Fix the Build", "  the build is red; BUILD again", "İstanbul"]);
    let m = search(&r, "build");
    assert_eq!(
        m,
        vec![
            Match { row: 0, start: 10, end: 15 },
            Match { row: 1, start: 6, end: 11 },
            Match { row: 1, start: 20, end: 25 },
        ]
    );
    assert_eq!(search(&r, "istan"), vec![Match { row: 2, start: 0, end: 5 }]);
    assert!(search(&r, "").is_empty());
    assert!(search(&r, "   ").is_empty());
    assert!(search(&r, "missing").is_empty());
}

#[test]
fn columns_count_wide_chars_as_drawn() {
    let r = rows(&["日本 ok"]);
    assert_eq!(search(&r, "ok"), vec![Match { row: 0, start: 5, end: 7 }]);
    assert_eq!(search(&r, "本"), vec![Match { row: 0, start: 2, end: 4 }]);
}

#[test]
fn steps_wrap_and_count_like_the_bar() {
    let r = rows(&["a x", "b x", "c x"]);
    let mut f = Find::open("s".into());
    assert_eq!(f.count_label(), "");
    for c in "x".chars() {
        f.type_char(c);
    }
    f.refresh(&r, 1);
    assert_eq!(f.count_label(), "2 of 3", "starts at the viewport's top");
    f.step(1);
    f.step(1);
    assert_eq!(f.count_label(), "1 of 3", "wraps forward");
    f.step(-1);
    assert_eq!(f.count_label(), "3 of 3", "wraps back");
    f.type_char('z');
    f.refresh(&r, 0);
    assert_eq!(f.count_label(), "No results");
    f.step(1);
    assert_eq!(f.current_match(), None);
}

#[test]
fn a_redraw_keeps_the_current_match() {
    let mut r = rows(&["x", "x", "x"]);
    let mut f = Find::open("s".into());
    f.type_char('x');
    f.refresh(&r, 0);
    f.step(1);
    r.push("x new reply".into());
    f.refresh(&r, 0);
    assert_eq!(f.count_label(), "2 of 4");
}

#[test]
fn reveals_only_an_offscreen_match() {
    let r: Vec<String> = (0..100).map(|i| format!("row {i}")).collect();
    let mut f = Find::open("s".into());
    for c in "row 70".chars() {
        f.type_char(c);
    }
    f.refresh(&r, 0);
    assert_eq!(f.reveal_offset(65, 20, 100), None, "already on screen");
    assert_eq!(f.reveal_offset(0, 20, 100), Some(64), "a third down from the top");
    assert_eq!(f.reveal_offset(0, 60, 100), Some(40), "clamped to the last page");
}
