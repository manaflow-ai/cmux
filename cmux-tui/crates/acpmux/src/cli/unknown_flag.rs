//! A flag that another command takes, given to one that does not, is refused with what does
//! take it and what this command does instead, not with clap's bare usage line and its nearest
//! spelling. The gui-push coordinator (2026-10-20), word for word: "acpmux send --no-wait
//! --prompt-file FILE gives a bare usage line without saying --prompt-file isn't a send flag."
//! (clap suggested `--prompt-id`.)
//!
//! The refusal is a usage error (exit 2) with `data.reason` `usage.unknown_flag`, `data.flag`,
//! `data.command`, `data.takenBy` (the commands that take the flag) and `data.try` (a command to
//! run instead), and the message ends with that command, as the daemon's refusals do
//! (`server/remote_guard/hint.rs`). A flag no command takes keeps clap's own error.

use crate::cli::errors::{AppError, Code};
use crate::harness_health::channel::quote;
use clap::error::{ContextKind, ContextValue, ErrorKind};
use serde_json::json;
use std::ffi::OsString;

/// The refusal for clap's error `e` on `argv` (the program name first, its command word at
/// `at`), when it is a long flag the command does not take and another command does; `cli` is
/// the grammar it was parsed with and `program` how it is run (`acpmux`, `cmux acp`).
pub(crate) fn explain(
    e: &clap::Error,
    cli: &clap::Command,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<AppError> {
    if e.kind() != ErrorKind::UnknownArgument {
        return None;
    }
    let Some(ContextValue::String(given)) = e.get(ContextKind::InvalidArg) else {
        return None;
    };
    let flag = given.split('=').next().unwrap_or(given);
    let long = flag.strip_prefix("--").filter(|l| !l.is_empty())?;
    let words: Vec<String> = argv.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    let command = cli.find_subcommand(words.get(at)?)?;
    let name = command.get_name();
    // Only a command's own unknown flag: a subcommand of it has its own grammar.
    if command.has_subcommands() {
        return None;
    }
    let takes = |c: &clap::Command| c.get_arguments().any(|a| a.get_long() == Some(long));
    let taken_by: Vec<&str> = cli
        .get_subcommands()
        .filter(|c| c.get_name() != name && !c.is_hide_set() && takes(c))
        .map(clap::Command::get_name)
        .collect();
    if taken_by.is_empty() {
        return None;
    }
    let takers = taken_by
        .iter()
        .map(|t| {
            let aliases: Vec<String> = cli
                .find_subcommand(t)
                .into_iter()
                .flat_map(|c| c.get_visible_aliases().chain(c.get_aliases()))
                .map(|a| format!("`{a}`"))
                .collect();
            if aliases.is_empty() {
                format!("`{t}`")
            } else {
                format!("`{t}` (also {})", aliases.join(", "))
            }
        })
        .collect::<Vec<_>>()
        .join(", ");
    let (instead, try_command) = match (name, long) {
        ("send", "prompt-file") => {
            let rest = &words[at + 1..];
            let line = send_from_file(command, rest, program);
            let instead = "send reads its prompt from stdin when it has no prompt words or `-`";
            (instead.to_owned(), line)
        }
        _ => (format!("`{program} {name} --help` lists the flags {name} takes"), None),
    };
    let try_command = try_command.unwrap_or_else(|| format!("{program} {name} --help"));
    let flag = format!("--{long}");
    let message =
        format!("{name} takes no {flag}: {takers} takes it. {instead}. Try: {try_command}");
    let data = json!({
        "reason": "usage.unknown_flag",
        "flag": flag,
        "command": name,
        "takenBy": taken_by,
        "try": try_command,
    });
    Some(AppError::new(Code::Usage, "unknown_flag", message).with_data(data))
}

/// `send`'s words `rest` with `--prompt-file FILE` taken out and the file read on stdin:
/// `acpmux send ... NAME - < FILE`. `None` when they carry prompt words too, which send would
/// send instead of stdin.
fn send_from_file(send: &clap::Command, rest: &[String], program: &str) -> Option<String> {
    let mut kept = Vec::new();
    let mut file = None;
    let mut positional = 0;
    let mut i = 0;
    while i < rest.len() {
        let word = &rest[i];
        if word == "--" {
            positional += rest.len() - i - 1;
            kept.extend(rest[i..].iter().cloned());
            break;
        }
        if let Some(value) = word.strip_prefix("--prompt-file=") {
            file = Some(value.to_owned());
            i += 1;
            continue;
        }
        if word == "--prompt-file" {
            file = rest.get(i + 1).cloned();
            i += 2;
            continue;
        }
        let takes_value = |a: &clap::Arg| a.get_action().takes_values();
        let separate = if let Some(long) = word.strip_prefix("--") {
            !long.contains('=')
                && send.get_arguments().any(|a| a.get_long() == Some(long) && takes_value(a))
        } else if let Some(shorts) = word.strip_prefix('-').filter(|s| !s.is_empty()) {
            // The last short of a group takes the next word when it takes a value.
            let last = shorts.chars().last();
            shorts.chars().count() == 1
                && send.get_arguments().any(|a| a.get_short() == last && takes_value(a))
        } else {
            positional += 1;
            false
        };
        kept.push(word.clone());
        if separate && let Some(value) = rest.get(i + 1) {
            kept.push(value.clone());
            i += 1;
        }
        i += 1;
    }
    match positional {
        0 => kept.push("NAME".to_owned()),
        1 => {}
        _ => return None,
    }
    let file = file.map(|f| quote(&f)).unwrap_or_else(|| "FILE".to_owned());
    let words: Vec<String> = kept.iter().map(|w| quote(w)).collect();
    Some(format!("{program} send {} - < {file}", words.join(" ")))
}

#[cfg(test)]
mod tests {
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
        assert!(
            e.message.starts_with("send takes no --prompt-file: `new` (also "),
            "{}",
            e.message
        );
        assert!(e.message.contains("`run`") && e.message.contains("`exec`"), "{}", e.message);
        assert!(e.message.ends_with("Try: acpmux send --no-wait lane - < 'my brief.md'"));
        // A value flag before it keeps its value; no session yet names the place for one.
        let e = refusal(&["send", "--from", "me", "--prompt-file=b.md"]).unwrap();
        assert_eq!(e.data.unwrap()["try"], "acpmux send --from me NAME - < b.md");
        // Prompt words too: send would send them, not the file, so the try is its help.
        let e = refusal(&["send", "lane", "hi", "--prompt-file", "b.md"]).unwrap();
        assert_eq!(e.data.unwrap()["try"], "acpmux send --help");
    }

    #[test]
    fn a_flag_no_command_takes_keeps_clap_s_error() {
        assert!(refusal(&["send", "lane", "--no-such-flag"]).is_none());
        assert!(refusal(&["send", "lane", "-Z"]).is_none());
        assert!(refusal(&["--json", "send", "lane"]).is_none(), "parses");
    }
}
