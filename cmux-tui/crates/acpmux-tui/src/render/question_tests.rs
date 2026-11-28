use super::*;

#[test]
fn a_long_question_wraps_whole_at_word_breaks() {
    let q = "Should I run the migration against the staging database now, or wait until the backup finishes?";
    let lines = wrap_text(q, 30);
    assert!(lines.len() > 1);
    assert!(lines.iter().all(|l| l.width() <= 30), "{lines:?}");
    assert_eq!(lines.join(" "), q);
}

#[test]
fn a_very_long_one_stops_at_eight_lines() {
    let q = "word ".repeat(200);
    let lines = wrap_text(&q, 20);
    assert_eq!(lines.len(), MAX_TEXT_LINES);
    assert!(lines.last().unwrap().ends_with('…'));
    assert!(lines.iter().all(|l| l.width() <= 20));
}

#[test]
fn a_command_wider_than_the_card_breaks_inside_it() {
    let cmd = "rm -rf /tmp/a-very-long-generated-directory-name-that-has-no-spaces-at-all";
    let lines = wrap_text(cmd, 24);
    assert!(lines.iter().all(|l| l.width() <= 24), "{lines:?}");
    assert_eq!(lines.concat().replace(' ', ""), cmd.replace(' ', ""));
    assert_eq!(wrap_text("", 24), vec![String::new()]);
}
