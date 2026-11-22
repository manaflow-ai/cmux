//! Root words agents reach for that acpmux spells another way. An agent diagnosing a closed
//! session typed `acpmux events NAME --tail 25` and `acpmux log NAME`, and got only
//! "unrecognized subcommand" (Leo, 2026-11-21: "the tool itself should be improved and/or your
//! thing should also be acceptable input"). `events`, `log` and `logs` are now names of `tail`
//! itself (`command.rs`); this module takes the rest:
//!
//! - a word that only reads ([`RUNS`]: `show NAME` is `session info NAME`) runs that command,
//!   with a note on stderr naming it, so the next call uses its own name;
//! - a word that changes something ([`SUGGESTS`]: `close NAME`) is refused with the command it
//!   means as `data.try`, never run: a guess must not stop or start a chat;
//! - any other unknown root word is refused with the nearest real command by spelling, when
//!   clap offered none.
//!
//! Each runs only after the word failed to parse and no command group takes it
//! (`unknown_command::explain` answers those first), so a real command always wins.

use crate::cli::errors::{AppError, Code};
use crate::harness_health::channel::quote;
use clap::error::{ContextKind, ContextValue, ErrorKind};
use serde_json::json;
use std::ffi::OsString;

/// Read-only words and the command each one runs.
pub(crate) const RUNS: &[(&str, &[&str])] = &[
    ("show", &["session", "info"]),
    ("describe", &["session", "info"]),
    ("inspect", &["session", "info"]),
    ("details", &["session", "info"]),
    ("output", &["last"]),
    ("replies", &["last"]),
    ("read", &["last"]),
    ("transcript", &["tail"]),
    ("journal", &["tail"]),
    ("sessions", &["ls"]),
];

/// Words that change something and the command each one means; refused, never run.
pub(crate) const SUGGESTS: &[(&str, &[&str])] = &[
    ("close", &["session", "stop"]),
    ("end", &["session", "stop"]),
    ("terminate", &["session", "stop"]),
    ("spawn", &["new"]),
    ("launch", &["new"]),
    ("create", &["new"]),
    ("msg", &["send"]),
    ("tell", &["send"]),
];

/// The unknown root word clap refused in `e`, when it is the word at `at` of `argv`.
fn unknown_root_word(e: &clap::Error, argv: &[OsString], at: usize) -> Option<String> {
    if e.kind() != ErrorKind::InvalidSubcommand {
        return None;
    }
    let Some(ContextValue::String(given)) = e.get(ContextKind::InvalidSubcommand) else {
        return None;
    };
    (argv.get(at).map(|a| a.to_string_lossy()) == Some(given.as_str().into()))
        .then(|| given.clone())
}

fn lookup(
    table: &[(&str, &'static [&'static str])],
    word: &str,
) -> Option<&'static [&'static str]> {
    table.iter().find(|(w, _)| *w == word).map(|(_, to)| *to)
}

/// `argv` with the read-only word at `at` replaced by its command, and the note that says so;
/// None when the refused word is no such word.
pub(crate) fn rewrite(
    e: &clap::Error,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<(Vec<OsString>, String)> {
    let word = unknown_root_word(e, argv, at)?;
    let to = lookup(RUNS, &word)?;
    let mut out: Vec<OsString> = argv.get(..at)?.to_vec();
    out.extend(to.iter().map(OsString::from));
    out.extend(argv.get(at + 1..).unwrap_or_default().iter().cloned());
    let note = format!("{program}: `{word}` is `{program} {}`; running that", to.join(" "));
    Some((out, note))
}

/// The refusal of an unknown root word: the command a changing word means, else the nearest
/// command by spelling when clap suggested none. `cli` is the grammar `argv` was parsed with.
pub(crate) fn refusal(
    e: &clap::Error,
    cli: &clap::Command,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<AppError> {
    let word = unknown_root_word(e, argv, at)?;
    let rest: Vec<String> = argv
        .get(at + 1..)
        .unwrap_or_default()
        .iter()
        .map(|a| quote(&a.to_string_lossy()))
        .collect();
    let try_line = |to: &[&str]| {
        std::iter::once(program.to_owned())
            .chain(to.iter().map(|w| (*w).to_owned()))
            .chain(rest.iter().cloned())
            .collect::<Vec<_>>()
            .join(" ")
    };
    if let Some(to) = lookup(SUGGESTS, &word) {
        let try_command = try_line(to);
        let message = format!(
            "{program} has no command {word}: `{program} {}` is what it means, and it changes \
             the session, so it was not run. Try: {try_command}",
            to.join(" ")
        );
        let data = json!({"reason": "usage.unknown_command", "command": word,
            "meant": to.join(" "), "try": try_command});
        return Some(AppError::new(Code::Usage, "unknown_command", message).with_data(data));
    }
    if matches!(e.get(ContextKind::SuggestedSubcommand), Some(ContextValue::Strings(s)) if !s.is_empty())
    {
        return None;
    }
    let near = nearest(cli, &word)?;
    let try_command = try_line(&[near.as_str()]);
    let message = format!(
        "{program} has no command {word}; the nearest is `{program} {near}`. Try: {try_command}"
    );
    let data = json!({"reason": "usage.unknown_command", "command": word, "suggested": [near],
        "try": try_command});
    Some(AppError::new(Code::Usage, "unknown_command", message).with_data(data))
}

/// The visible root command (or alias) nearest `word` by edit distance, within a third of the
/// longer word (at least 1, at most 3); the first in help order wins a tie.
fn nearest(cli: &clap::Command, word: &str) -> Option<String> {
    let word = word.to_lowercase();
    let mut best: Option<(usize, String)> = None;
    for command in cli.get_subcommands().filter(|c| !c.is_hide_set()) {
        let name = command.get_name();
        if name == "help" {
            continue;
        }
        for spelling in std::iter::once(name).chain(command.get_all_aliases()) {
            let d = distance(&word, spelling);
            let bound = (word.chars().count().max(spelling.chars().count()) / 3).clamp(1, 3);
            if d <= bound && best.as_ref().is_none_or(|(b, _)| d < *b) {
                best = Some((d, name.to_owned()));
            }
        }
    }
    best.map(|(_, name)| name)
}

/// Levenshtein distance by chars.
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut prev = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let here = row[j + 1];
            row[j + 1] = if ca == *cb { prev } else { 1 + prev.min(here).min(row[j]) };
            prev = here;
        }
    }
    row[b.len()]
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
    fn every_listed_word_is_free_and_names_a_real_command() {
        let mut cli = crate::cli::command::Cli::command();
        for (word, to) in RUNS.iter().chain(SUGGESTS) {
            assert!(!crate::cli::command::owns_word(word), "{word} is a real command now");
            // The command it names parses (with a session where it takes one).
            let parses = |words: &[&str], cli: &mut clap::Command| {
                let mut line = vec!["acpmux"];
                line.extend(to.iter().copied());
                line.extend(words);
                cli.try_get_matches_from_mut(line).is_ok()
            };
            assert!(
                parses(&["lane"], &mut cli) || parses(&["lane", "hi"], &mut cli),
                "{word}: {to:?} does not parse"
            );
        }
    }

    #[test]
    fn events_log_and_logs_are_tail_with_tail_n_and_follow() {
        use crate::cli::command::{Cli, Command, SessionCmd};
        use clap::Parser as _;
        for word in ["events", "log", "logs", "tail"] {
            for count in [["--tail", "25"], ["-n", "25"], ["--last", "25"]] {
                let cli = Cli::try_parse_from([
                    "acpmux", "--json", word, "lane", count[0], count[1], "--follow",
                ])
                .unwrap_or_else(|e| panic!("{word} {count:?}: {e}"));
                assert!(cli.json);
                match cli.command {
                    Some(Command::Tail { session, last, follow, .. }) => {
                        assert_eq!((session.as_str(), last, follow), ("lane", 25, true), "{word}");
                    }
                    _ => panic!("{word} is not tail"),
                }
                let cli = Cli::try_parse_from([
                    "acpmux", "session", word, "lane", count[0], count[1], "-f",
                ])
                .unwrap_or_else(|e| panic!("session {word} {count:?}: {e}"));
                match cli.command {
                    Some(Command::Session(SessionCmd::Tail { last, follow, .. })) => {
                        assert_eq!((last, follow), (25, true), "session {word}");
                    }
                    _ => panic!("session {word} is not session tail"),
                }
            }
        }
    }

    #[test]
    fn a_read_only_word_runs_its_command() {
        let (_, argv, e) = parse_error(&["--json", "show", "lane one"]);
        let (rewritten, note) = rewrite(&e, &argv, 2, "acpmux").expect("a rewrite");
        assert_eq!(rewritten, super::tests::argv(&["--json", "session", "info", "lane one"]));
        assert_eq!(note, "acpmux: `show` is `acpmux session info`; running that");
        let (_, argv, e) = parse_error(&["output", "lane", "-n", "2"]);
        let (rewritten, _) = rewrite(&e, &argv, 1, "acpmux").expect("a rewrite");
        assert_eq!(rewritten, super::tests::argv(&["last", "lane", "-n", "2"]));
        // A word that changes something is never run.
        let (_, argv, e) = parse_error(&["close", "lane"]);
        assert!(rewrite(&e, &argv, 1, "acpmux").is_none());
    }

    #[test]
    fn a_changing_word_is_refused_with_the_command_it_means() {
        let (cli, argv, e) = parse_error(&["close", "lane one"]);
        let refused = refusal(&e, &cli, &argv, 1, "acpmux").expect("a refusal");
        let data = refused.data.unwrap();
        assert_eq!(data["reason"], "usage.unknown_command");
        assert_eq!(data["meant"], "session stop");
        assert_eq!(data["try"], "acpmux session stop 'lane one'");
    }

    #[test]
    fn any_other_word_gets_the_nearest_command() {
        let (cli, argv, e) = parse_error(&["sendd", "lane", "hi"]);
        // clap offers `send` itself here; under its own error the tip stands.
        let suggested = matches!(e.get(ContextKind::SuggestedSubcommand),
            Some(ContextValue::Strings(s)) if !s.is_empty());
        let refused = refusal(&e, &cli, &argv, 1, "acpmux");
        assert_eq!(refused.is_none(), suggested);
        assert_eq!(nearest(&cli, "sendd").as_deref(), Some("send"));
        assert_eq!(nearest(&cli, "lss").as_deref(), Some("ls"));
        assert_eq!(nearest(&cli, "frobnicate-everything"), None);
    }

    #[test]
    fn edit_distance() {
        assert_eq!(distance("kitten", "sitting"), 3);
        assert_eq!(distance("", "ab"), 2);
        assert_eq!(distance("tail", "tail"), 0);
    }
}
