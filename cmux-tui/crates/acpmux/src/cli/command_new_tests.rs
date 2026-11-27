use super::*;
use clap::Parser;

#[test]
fn a_lone_prompt_with_spaces_stays_the_prompt() {
    let mut args = New::try_parse_from(["new", "fix the bug"]).unwrap().args;
    let notices = args.apply_compat();
    assert_eq!(args.prompt, ["fix the bug"]);
    assert!(args.name.is_none());
    assert!(notices.is_empty());
}

#[test]
fn a_detached_lone_name_is_the_name_not_the_prompt() {
    // `acpmux new codex-nightly-check -m codex -d` named the session "codex" and sent
    // the name as its first prompt (Leo, 2026-11-21: "under the name \"codex\" instead of
    // the one I gave it"). Placed or local, the word is the name.
    for argv in [
        &["new", "codex-nightly-check", "-m", "codex", "-d"][..],
        &["new", "-d", "codex-nightly-check", "--machine", "auto"][..],
        &["new", "--detach", "codex-nightly-check", "--machine", "far-host"][..],
    ] {
        let mut args = New::try_parse_from(argv).unwrap().args;
        let notices = args.apply_compat();
        assert_eq!(args.name.as_deref(), Some("codex-nightly-check"), "{argv:?}");
        assert!(args.prompt.is_empty(), "{argv:?}");
        assert!(args.detach, "{argv:?}");
        assert_eq!(notices.len(), 1, "{argv:?}");
    }
    // With -n given, the lone word is the prompt, as asked.
    let mut args = New::try_parse_from(["new", "-n", "probe", "-d", "continue"]).unwrap().args;
    args.apply_compat();
    assert_eq!(args.name.as_deref(), Some("probe"));
    assert_eq!(args.prompt, ["continue"]);
}

#[derive(Parser)]
struct New {
    #[command(flatten)]
    args: NewArgs,
}

#[test]
fn compatibility_spellings_keep_the_name_and_wait_on_local() {
    let mut args = New::try_parse_from([
        "new",
        "codex-nightly-check",
        "--harness",
        "codex",
        "--stay",
        "--wait",
    ])
    .unwrap()
    .args;
    let notices = args.apply_compat();
    assert_eq!(args.name.as_deref(), Some("codex-nightly-check"));
    assert!(args.prompt.is_empty());
    assert_eq!(args.host.as_deref(), Some("local"));
    assert!(args.detach);
    assert_eq!(notices.len(), 3);
}

#[test]
fn wait_with_an_explicit_name_keeps_the_name_without_a_prompt() {
    let mut args =
        New::try_parse_from(["new", "--name", "codex-nightly-check", "--stay", "--wait"])
            .unwrap()
            .args;
    let notices = args.apply_compat();
    assert_eq!(args.name.as_deref(), Some("codex-nightly-check"));
    assert!(args.prompt.is_empty());
    assert_eq!(args.host.as_deref(), Some("local"));
    assert!(args.detach);
    assert_eq!(notices.len(), 2);
}

#[test]
fn prompt_aliases_keep_their_single_positional_prompt() {
    for mut args in [
        New::try_parse_from(["new", "do the work", "--detach"]).unwrap().args,
        New::try_parse_from(["new", "do the work", "--quiet"]).unwrap().args,
    ] {
        args.apply_compat();
        assert_eq!(args.prompt, ["do the work"]);
        assert!(args.name.is_none());
    }
}

#[test]
fn wait_with_a_prompt_uses_an_explicit_name_to_disambiguate() {
    let mut args =
        New::try_parse_from(["new", "--name", "codex-nightly-check", "--wait", "do the work"])
            .unwrap()
            .args;
    args.apply_compat();
    assert_eq!(args.name.as_deref(), Some("codex-nightly-check"));
    assert_eq!(args.prompt, ["do the work"]);
    assert!(args.quiet);
    assert!(!args.detach);
}

#[test]
fn wait_without_a_prompt_creates_without_opening_the_tui() {
    let mut args = New::try_parse_from(["new", "--wait"]).unwrap().args;
    let notices = args.apply_compat();
    assert!(args.detach);
    assert!(!args.quiet);
    assert_eq!(notices.len(), 1);
}
