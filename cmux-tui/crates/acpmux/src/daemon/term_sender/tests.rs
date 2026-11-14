use super::*;

#[test]
fn a_ps_row_gives_the_parent_and_the_command() {
    assert_eq!(
        parse_row("  4021 /bin/sh -c kill -TERM 12\n"),
        Some((4021, "/bin/sh -c kill -TERM 12".into()))
    );
    assert_eq!(parse_row(""), None);
}

#[test]
fn this_process_is_described_with_its_command() {
    let text = describe(std::process::id() as i32);
    assert!(text.starts_with(&format!("pid {} (", std::process::id())), "{text}");
    assert!(!text.contains("already gone"), "{text}");
}
