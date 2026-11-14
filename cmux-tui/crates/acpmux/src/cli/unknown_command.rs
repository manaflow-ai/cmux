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
mod tests;
