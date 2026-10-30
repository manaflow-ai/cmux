//! Parse errors that leave an agent a way out. An unknown root word that a command group takes
//! (`acpmux restart NAME`, which is `acpmux session restart NAME`) is refused with that command,
//! not with clap's nearest spellings: for `acpmux stop NAME` clap offered `shutdown`, which stops
//! the daemon. Under `--json` every parse error is the error envelope (`usage`, exit 2) with a
//! `data.reason` of `usage.*`, never clap's plain text. A lone `-` among `new`'s prompt words is
//! refused: it would go as the text "-", and only `--prompt-file -` reads stdin.

use crate::cli::errors::{AppError, Code};
use crate::harness_health::channel::quote;
use clap::error::{ContextKind, ContextValue, ErrorKind};
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
    let named = rest.iter().any(|w| !w.starts_with('-'));
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
        data["suggested"] = json!(suggested);
    }
    Some(AppError::new(Code::Usage, "usage", message).with_data(data))
}

/// The refusal of `new`'s prompt `words` when one of them is a lone `-`, which would go as the
/// text "-": `data.try` is the same command without that word and with `--prompt-file -`, which
/// reads stdin (before a `--`, and only when no `--prompt-file` is given). `argv` is the command
/// line, its command word at `at`; `new` is its grammar, which says which flags take a value.
pub(crate) fn stdin_dash(
    words: &[String],
    new: &clap::Command,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<AppError> {
    if !words.iter().any(|w| w == "-") {
        return None;
    }
    let rest: Vec<String> = argv
        .get(at + 1..)
        .unwrap_or_default()
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let takes_value = |a: &clap::Arg| a.get_action().takes_values();
    let mut kept: Vec<String> = Vec::new();
    let mut separator = None;
    let mut has_file = false;
    let mut i = 0;
    while let Some(word) = rest.get(i) {
        i += 1;
        if separator.is_some() {
            if word != "-" {
                kept.push(word.clone());
            }
            continue;
        }
        if word == "--" {
            separator = Some(kept.len());
            kept.push(word.clone());
            continue;
        }
        let value_follows = if let Some(long) = word.strip_prefix("--") {
            let name = long.split('=').next().unwrap_or(long);
            has_file |= name == "prompt-file";
            !long.contains('=')
                && new.get_arguments().any(|a| a.get_long() == Some(name) && takes_value(a))
        } else if let Some(shorts) = word.strip_prefix('-').filter(|s| !s.is_empty()) {
            let last = shorts.chars().last();
            shorts.chars().count() == 1
                && new.get_arguments().any(|a| a.get_short() == last && takes_value(a))
        } else {
            false
        };
        if word == "-" {
            continue;
        }
        kept.push(word.clone());
        if value_follows && let Some(value) = rest.get(i) {
            kept.push(value.clone());
            i += 1;
        }
    }
    if !has_file {
        let at = separator.unwrap_or(kept.len());
        kept.splice(at..at, ["--prompt-file".to_owned(), "-".to_owned()]);
    }
    let command = argv.get(at).map(|a| a.to_string_lossy().into_owned()).unwrap_or_default();
    let try_command = std::iter::once(format!("{program} {command}"))
        .chain(kept.iter().map(|w| quote(w)))
        .collect::<Vec<_>>()
        .join(" ");
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
        let e = cli.try_get_matches_from_mut(argv.clone()).err().expect("parses");
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
            let e = cli.try_get_matches_from_mut(argv.clone()).err().expect("parses");
            explain(&e, &cli, &argv, 1, "prog").map(|r| r.data.unwrap()["try"].clone())
        };
        assert_eq!(error(&["wipe", "lane"]), None);
        assert_eq!(error(&["wipe"]), Some(json!("prog daemon wipe")));
        assert_eq!(error(&["stop", "lane"]), Some(json!("prog session stop lane")));
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
        let new = cli.find_subcommand(args[0]).expect("new");
        let argv = argv(args);
        let words: Vec<String> = match cli.clone().try_get_matches_from(argv.clone()) {
            Ok(m) => m
                .subcommand_matches(new.get_name())?
                .get_many::<String>("prompt")
                .map(|v| v.cloned().collect())
                .unwrap_or_default(),
            Err(e) => panic!("{args:?}: {e}"),
        };
        let refusal = stdin_dash(&words, new, &argv, 1, "acpmux")?;
        Some(refusal.data.unwrap()["try"].as_str().unwrap().to_owned())
    }

    #[test]
    fn a_lone_dash_prompt_word_points_at_prompt_file() {
        assert_eq!(
            try_for(&["new", "fix it", "-", "-m", "codex"]).as_deref(),
            Some("acpmux new 'fix it' -m codex --prompt-file -")
        );
        // A flag's own value `-` stays; after `--` the option goes before it.
        assert_eq!(
            try_for(&["new", "-n", "-", "--", "fix", "-"]).as_deref(),
            Some("acpmux new -n - --prompt-file - -- fix")
        );
        // `--prompt-file` already given: it is kept, not added again.
        assert_eq!(
            try_for(&["run", "-", "--prompt-file", "brief.md"]).as_deref(),
            Some("acpmux run --prompt-file brief.md")
        );
        assert_eq!(try_for(&["new", "fix", "a-b"]), None);
    }
}
