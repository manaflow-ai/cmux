//! Parse errors that leave an agent a way out. An unknown root word that a command group takes
//! (`acpmux restart NAME`, which is `acpmux session restart NAME`) is refused with that command,
//! not with clap's nearest spellings: for `acpmux stop NAME` clap offered `shutdown`, which stops
//! the daemon. Under `--json` every parse error is the error envelope (`usage`, exit 2) with a
//! `data.reason` of `usage.*`, never clap's plain text. A lone `-` among `new`'s prompt words is
//! refused: it would go as the text "-", and only `--prompt-file -` reads stdin.

use crate::cli::errors::{AppError, Code};
use crate::harness_health::channel::quote;
use clap::error::{ContextKind, ContextValue, ErrorKind};
use cmux_json::JsonSet as _;
use serde_json::json;
use std::ffi::OsString;

/// The refusal for clap's error `e` on `argv` (its command word at `at`) when the unknown word is
/// a root command word that a command group takes: `data.try` is that group's command with the
/// rest of the words. `cli` is the grammar it was parsed with and `program` how it is run.
pub(crate) fn explain(
    e: &clap::Error,
    cli: &clap::Command,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<AppError> {
    if e.kind() != ErrorKind::InvalidSubcommand {
        return None;
    }
    let Some(ContextValue::String(given)) = e.get(ContextKind::InvalidSubcommand) else {
        return None;
    };
    let words: Vec<String> = argv.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    // Only a root word: a group's own unknown word keeps clap's error.
    if words.get(at) != Some(given) {
        return None;
    }
    let names = |c: &clap::Command| {
        std::iter::once(c.get_name()).chain(c.get_all_aliases()).any(|n| n == given)
    };
    let found: Vec<(&str, &clap::Command)> = cli
        .get_subcommands()
        .filter(|g| !g.is_hide_set() && g.has_subcommands())
        .filter_map(|g| {
            let c = g.get_subcommands().find(|c| !c.is_hide_set() && names(c))?;
            Some((g.get_name(), c))
        })
        .collect();
    let rest = words.get(at + 1..).unwrap_or_default();
    // Words after it name something (a session): only a command that takes them, so
    // `acpmux restart NAME` is `session restart NAME`, never `daemon restart`.
    let takes_words = |c: &clap::Command| c.get_positionals().next().is_some();
    // A word is positional when it is no flag, or comes after `--` (or is a lone `-`).
    let separator = rest.iter().position(|w| w == "--");
    let named = rest.iter().enumerate().any(|(i, w)| {
        separator.is_some_and(|s| i > s)
            || (w.as_str() != "--" && (w == "-" || !w.starts_with('-')))
    });
    let fitting: Vec<&str> =
        found.iter().filter(|(_, c)| !named || takes_words(c)).map(|(g, _)| *g).collect();
    // None takes them: clap's own error, never a command that would drop the words (a daemon
    // command for a session's name).
    let groups = if named { fitting } else { found.iter().map(|(g, _)| *g).collect() };
    let first = *groups.first()?;
    let try_command = [program, first, given.as_str()]
        .into_iter()
        .map(str::to_owned)
        .chain(rest.iter().map(|w| quote(w)))
        .collect::<Vec<_>>()
        .join(" ");
    let takers =
        groups.iter().map(|g| format!("`{program} {g} {given}`")).collect::<Vec<_>>().join(", ");
    let message = format!("{program} has no command {given}: {takers} is. Try: {try_command}");
    let data = json!({
        "reason": "usage.unknown_command",
        "command": given,
        "takenBy": groups,
        "try": try_command,
    });
    Some(AppError::new(Code::Usage, "unknown_command", message).with_data(data))
}

/// Clap's error `e` as the `--json` error envelope's error: `usage` (exit 2), its words as the
/// message, `data.reason` `usage.*` by its kind. None for help and the version, which are not
/// errors.
pub(crate) fn envelope(e: &clap::Error, program: &str) -> Option<AppError> {
    let reason = match e.kind() {
        ErrorKind::DisplayHelp | ErrorKind::DisplayVersion => return None,
        ErrorKind::InvalidSubcommand => "usage.unknown_command",
        ErrorKind::UnknownArgument => "usage.unknown_argument",
        ErrorKind::MissingRequiredArgument => "usage.missing_argument",
        ErrorKind::MissingSubcommand | ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand => {
            "usage.missing_command"
        }
        ErrorKind::InvalidValue
        | ErrorKind::ValueValidation
        | ErrorKind::NoEquals
        | ErrorKind::InvalidUtf8 => "usage.invalid_value",
        ErrorKind::ArgumentConflict => "usage.conflict",
        ErrorKind::TooManyValues | ErrorKind::TooFewValues | ErrorKind::WrongNumberOfValues => {
            "usage.wrong_values"
        }
        _ => "usage.invalid",
    };
    let text = e.render().to_string();
    let message = text.trim().strip_prefix("error: ").unwrap_or(text.trim()).to_owned();
    let mut data = json!({"reason": reason, "try": format!("{program} --help")});
    if let Some(ContextValue::Strings(suggested)) = e.get(ContextKind::SuggestedSubcommand) {
        data.set("suggested", json!(suggested));
    }
    Some(AppError::new(Code::Usage, "usage", message).with_data(data))
}

/// The refusal of `new`'s command line when one of its prompt words is a lone `-`, which would
/// go as the text "-": `data.try` is the same line without those words and with
/// `--prompt-file -`, which reads stdin, right after the command word, where no flag can take it
/// as its value (none when one is given). A `-` is a prompt word when the line parsed without it
/// has the same prompt less that one `-`; a flag's own value `-` stays (clap's indices are no
/// argv positions: a short-flag cluster and `--` shift them). `grammar` parses `argv`, whose
/// command word is at `at`; `new` is that command's parse.
pub(crate) fn stdin_dash(
    grammar: &clap::Command,
    new: &clap::ArgMatches,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<AppError> {
    let prompt = |m: &clap::ArgMatches| -> Vec<String> {
        m.get_many::<String>("prompt").into_iter().flatten().cloned().collect()
    };
    let dashes = |words: &[String]| words.iter().filter(|w| *w == "-").count();
    let words_of =
        |words: &[String]| -> Vec<String> { words.iter().filter(|w| *w != "-").cloned().collect() };
    let parsed = prompt(new);
    if dashes(&parsed) == 0 {
        return None;
    }
    let kept_words = words_of(&parsed);
    let mut line: Vec<OsString> = argv.to_vec();
    let mut left = dashes(&parsed);
    let mut p = at + 1;
    while left > 0 && p < line.len() {
        if line.get(p).is_some_and(|word| word != "-") {
            p += 1;
            continue;
        }
        let mut without = line.clone();
        without.remove(p);
        let fits = grammar.clone().try_get_matches_from(&without).ok().is_some_and(|m| {
            m.subcommand().is_some_and(|(_, sub)| {
                let words = prompt(sub);
                dashes(&words) + 1 == left && words_of(&words) == kept_words
            })
        });
        if fits {
            line = without;
            left -= 1;
        } else {
            p += 1;
        }
    }
    let words: Vec<String> = line.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    let command = words.get(at).cloned().unwrap_or_default();
    let mut try_line = vec![format!("{program} {command}")];
    if !new.contains_id("prompt_file") {
        try_line.extend(["--prompt-file".to_owned(), "-".to_owned()]);
    }
    try_line.extend(words.iter().skip(at + 1).map(|w| quote(w)));
    let try_command = try_line.join(" ");
    let message = format!(
        "{command}'s words are its prompt, so `-` would be sent as the text \"-\" (the session \
         name is `-n NAME`); `--prompt-file -` reads the prompt from stdin. Try: {try_command}"
    );
    let data = json!({"reason": "usage.prompt_stdin", "command": command, "try": try_command});
    Some(AppError::new(Code::Usage, "prompt_stdin", message).with_data(data))
}

#[cfg(test)]
mod tests {
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
}
