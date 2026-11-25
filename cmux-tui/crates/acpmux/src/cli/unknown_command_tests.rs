use super::*;
use clap::CommandFactory;

fn argv(args: &[&str]) -> Vec<OsString> {
    std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect()
}

fn parse_error(args: &[&str]) -> (clap::Command, Vec<OsString>, clap::Error) {
    let mut cli = crate::cli::command::Cli::command();
    let argv = argv(args);
    let e = cli.try_get_matches_from_mut(argv.clone()).expect_err("parses");
    (cli, argv, e)
}

#[test]
fn a_root_word_a_group_takes_names_that_command() {
    let (cli, argv, e) = parse_error(&["restart", "lane one"]);
    let refusal = explain(&e, &cli, &argv, 1, "acpmux").expect("a refusal");
    let data = refusal.data.unwrap();
    assert_eq!(data["reason"], "usage.unknown_command", "{data}");
    assert_eq!(data["takenBy"], json!(["session"]), "{data}");
    assert_eq!(data["try"], "acpmux session restart 'lane one'", "{data}");
    assert!(!refusal.message.contains("shutdown"), "{}", refusal.message);
}

#[test]
fn words_no_matching_command_takes_keep_clap_s_error() {
    // `daemon wipe` takes no words: `prog wipe lane` never points at it.
    let mut cli = clap::Command::new("prog")
        .subcommand(clap::Command::new("daemon").subcommand(clap::Command::new("wipe")))
        .subcommand(
            clap::Command::new("session")
                .subcommand(clap::Command::new("stop").arg(clap::Arg::new("name"))),
        );
    let mut error = |args: &[&str]| {
        let argv: Vec<OsString> =
            std::iter::once("prog").chain(args.iter().copied()).map(Into::into).collect();
        let e = cli.try_get_matches_from_mut(argv.clone()).expect_err("parses");
        explain(&e, &cli, &argv, 1, "prog").map(|r| r.data.unwrap()["try"].clone())
    };
    assert_eq!(error(&["wipe", "lane"]), None);
    assert_eq!(error(&["wipe"]), Some(json!("prog daemon wipe")));
    assert_eq!(error(&["stop", "lane"]), Some(json!("prog session stop lane")));
    // A name after `--` is a word too, even one that looks like a flag.
    assert_eq!(error(&["wipe", "--", "-n"]), None);
    assert_eq!(error(&["stop", "--", "-n"]), Some(json!("prog session stop -- -n")));
}

#[test]
fn a_word_no_group_takes_keeps_clap_s_error_but_is_json_under_json() {
    let (cli, argv, e) = parse_error(&["--json", "frobnicate"]);
    assert!(explain(&e, &cli, &argv, 2, "acpmux").is_none());
    let refusal = envelope(&e, "acpmux").expect("an envelope");
    assert_eq!(refusal.code as i32, 2);
    let v = refusal.envelope();
    assert_eq!(v["error"]["code"], "usage", "{v}");
    assert_eq!(v["error"]["data"]["reason"], "usage.unknown_command", "{v}");
    assert!(v["error"]["message"].as_str().unwrap().contains("frobnicate"), "{v}");
}

#[test]
fn help_and_version_are_not_errors() {
    let (_, _, e) = parse_error(&["--help"]);
    assert!(envelope(&e, "acpmux").is_none());
}

fn try_for(args: &[&str]) -> Option<String> {
    let cli = crate::cli::command::Cli::command();
    let argv = argv(args);
    let matches =
        cli.try_get_matches_from(argv.clone()).unwrap_or_else(|e| panic!("{args:?}: {e}"));
    let (_, new) = matches.subcommand()?;
    let at = argv.iter().skip(1).position(|a| a != "--json").map(|i| i + 1)?;
    let refusal = stdin_dash(&crate::cli::command::Cli::command(), new, &argv, at, "acpmux")?;
    Some(refusal.data.unwrap()["try"].as_str().unwrap().to_owned())
}

#[test]
fn a_lone_dash_prompt_word_points_at_prompt_file() {
    assert_eq!(
        try_for(&["new", "fix it", "-", "-m", "codex"]).as_deref(),
        Some("acpmux new --prompt-file - 'fix it' -m codex")
    );
    // A flag's own value `-` stays, in a short-flag cluster too; after `--` too.
    assert_eq!(
        try_for(&["new", "-n", "-", "--", "fix", "-"]).as_deref(),
        Some("acpmux new --prompt-file - -n - -- fix")
    );
    assert_eq!(
        try_for(&["new", "-dp", "-", "foo", "-"]).as_deref(),
        Some("acpmux new --prompt-file - -dp - foo")
    );
    // A global flag before the command word.
    assert_eq!(
        try_for(&["--json", "new", "fix", "-"]).as_deref(),
        Some("acpmux new --prompt-file - fix")
    );
    // `--prompt-file` already given: it is kept, not added again.
    assert_eq!(
        try_for(&["run", "-", "--prompt-file", "brief.md"]).as_deref(),
        Some("acpmux run --prompt-file brief.md")
    );
    assert_eq!(try_for(&["new", "fix", "a-b"]), None);
}
