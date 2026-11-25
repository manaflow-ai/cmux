use super::*;
use clap::CommandFactory;

fn refusal(args: &[&str]) -> Option<AppError> {
    let mut cli = crate::cli::command::Cli::command();
    let argv: Vec<OsString> =
        std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect();
    let e = cli.try_get_matches_from_mut(argv.clone()).err()?;
    let at = argv.iter().skip(1).position(|a| a != "--json").map(|i| i + 1)?;
    explain(&e, &cli, &argv, at, "acpmux")
}

#[test]
fn send_prompt_file_names_new_and_reads_the_file_on_stdin() {
    let e = refusal(&["send", "--no-wait", "--prompt-file", "my brief.md", "lane"]).unwrap();
    let data = e.data.clone().unwrap();
    assert_eq!(data["try"], "acpmux send --no-wait lane - < 'my brief.md'", "{data}");
    assert_eq!(data["takenBy"], json!(["new"]), "{data}");
    assert!(e.message.starts_with("send takes no --prompt-file: `new` (also "), "{}", e.message);
    assert!(e.message.contains("`run`") && e.message.contains("`exec`"), "{}", e.message);
    assert!(e.message.ends_with("Try: acpmux send --no-wait lane - < 'my brief.md'"));
    // A value flag before it keeps its value; no session yet names the place for one.
    let e = refusal(&["send", "--from", "me", "--prompt-file=b.md"]).unwrap();
    assert_eq!(e.data.unwrap()["try"], "acpmux send --from me NAME - < b.md");
    // Prompt words too: send would send them, not the file, so the try is its help.
    let e = refusal(&["send", "lane", "hi", "--prompt-file", "b.md"]).unwrap();
    assert_eq!(e.data.unwrap()["try"], "acpmux send --help");
}

/// `--host`, now a hidden alias of `--machine`, is still explained as a flag other commands
/// take, under the spelling the person typed.
#[test]
fn an_old_flag_spelling_is_explained_like_its_new_one() {
    for flag in ["--host", "--machine"] {
        let e = refusal(&["history", "lane", flag, "box"]).unwrap_or_else(|| panic!("{flag}"));
        let data = e.data.clone().unwrap();
        assert_eq!(data["reason"], "usage.unknown_flag", "{data}");
        assert_eq!(data["flag"], flag, "{data}");
        let taken: Vec<&str> =
            data["takenBy"].as_array().unwrap().iter().filter_map(|v| v.as_str()).collect();
        assert!(taken.contains(&"new") && taken.contains(&"ls"), "{data}");
    }
}

#[test]
fn a_flag_no_command_takes_keeps_clap_s_error() {
    assert!(refusal(&["send", "lane", "--no-such-flag"]).is_none());
    assert!(refusal(&["send", "lane", "-Z"]).is_none());
    assert!(refusal(&["--json", "send", "lane"]).is_none(), "parses");
}
