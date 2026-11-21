//! A flag that another command takes, given to one that does not, is refused with what does
//! take it and what this command does instead, not with clap's bare usage line and its nearest
//! spelling. The gui-push coordinator (2026-10-20), word for word: "acpmux send --no-wait
//! --prompt-file FILE gives a bare usage line without saying --prompt-file isn't a send flag."
//! (clap suggested `--prompt-id`.)
//!
//! The refusal is a usage error (exit 2) with `data.reason` `usage.unknown_flag`, `data.flag`,
//! `data.command`, `data.takenBy` (the commands that take the flag) and `data.try` (a command to
//! run instead), and the message ends with that command, as the daemon's refusals do
//! (`server/remote_guard/hint.rs`).
//!
//! A flag that is one of this command's own flags in another case convention (`--no_wait`,
//! `--noWait`, `--NO-WAIT` for `--no-wait`) is read as that flag and the call runs, with one line
//! on stderr naming the spelling it took, so the caller learns the real name (`repair`). Case and
//! separators are the only thing that folds: two flags whose meanings differ are never aliased,
//! and a spelling that several real flags answer to is refused naming each, never guessed.
//!
//! A flag no command takes and no fold reaches is refused by name, with this command's help, and
//! never with a nearest spelling: clap's own tip for `acpmux send --file` was `--title`, an
//! unrelated flag (Leo, 2026-11-21: "a wrong match is worse than an honest miss"). Only a fold or
//! a declared alias may point at a flag; anything else gets the usage.

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
    // By its name or a hidden alias: `--host` is `--machine`'s old spelling.
    let takes = |c: &clap::Command| {
        c.get_arguments().any(|a| {
            a.get_long() == Some(long) || a.get_all_aliases().is_some_and(|all| all.contains(&long))
        })
    };
    let taken_by: Vec<&str> = cli
        .get_subcommands()
        .filter(|c| c.get_name() != name && !c.is_hide_set() && takes(c))
        .map(clap::Command::get_name)
        .collect();
    if taken_by.is_empty() {
        // No command takes it and no fold reached it: name the flag and give this command's
        // help. Never a nearest spelling, which sent a caller at `--title` for `--file`.
        let flag = format!("--{long}");
        let try_command = format!("{program} {name} --help");
        let message = format!(
            "{name} takes no {flag}, and no command does. `{try_command}` lists the flags \
             {name} takes. Try: {try_command}"
        );
        let data = json!({
            "reason": "usage.unknown_flag",
            "flag": flag,
            "command": name,
            "takenBy": Vec::<&str>::new(),
            "try": try_command,
        });
        return Some(AppError::new(Code::Usage, "unknown_flag", message).with_data(data));
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
            let rest = words.get(at + 1..).unwrap_or_default();
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

/// At most this many spellings are read in one call, so a repair can never loop.
pub(crate) const REPAIRS: usize = 8;

/// What `repair` found for one unknown flag.
pub(crate) enum Repair {
    /// The spelling is one real flag's, in another case convention: `argv` has it canonical.
    Took { argv: Vec<OsString>, given: String, canonical: String },
    /// Several real flags answer to the spelling: which was meant is refused, never picked.
    Ambiguous(Box<AppError>),
}

/// How flag spellings are compared: case and separators carry no meaning, so `--no_wait`,
/// `--noWait` and `--NO-WAIT` all fold to `nowait`. Nothing else folds. A fold is the whole
/// name, never a prefix or an edit distance, so it cannot reach a flag the caller did not
/// spell: `--file` folds to `file` and reaches neither `--attach` nor `--title`.
fn fold(long: &str) -> String {
    long.chars().filter(|c| *c != '-' && *c != '_').flat_map(char::to_lowercase).collect()
}

/// The command `argv` names (its command word at `at`), following nested command words.
fn leaf<'c>(cli: &'c clap::Command, words: &[String], at: usize) -> Option<&'c clap::Command> {
    let mut command = cli.find_subcommand(words.get(at)?)?;
    let mut i = at + 1;
    while let Some(next) = words.get(i).and_then(|w| command.find_subcommand(w)) {
        command = next;
        i += 1;
    }
    Some(command)
}

/// Clap's error `e` reread: when the unknown long flag is one of this command's own flags in
/// another case convention, the argv to run instead, so the call the caller meant works. `None`
/// when no fold reaches a real flag, which leaves the refusal to `explain`.
///
/// Only a whole-name fold counts. A spelling two distinct flags answer to is `Ambiguous`:
/// picking one of two real flags for the caller would be far worse than the wasted call.
pub(crate) fn repair(
    e: &clap::Error,
    cli: &clap::Command,
    argv: &[OsString],
    at: usize,
    program: &str,
) -> Option<Repair> {
    if e.kind() != ErrorKind::UnknownArgument {
        return None;
    }
    let Some(ContextValue::String(given)) = e.get(ContextKind::InvalidArg) else {
        return None;
    };
    // A short flag has no case convention to read.
    let token = given.split('=').next().unwrap_or(given);
    let long = token.strip_prefix("--").filter(|l| !l.is_empty())?;
    let words: Vec<String> = argv.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    let command = leaf(cli, &words, at)?;
    let want = fold(long);
    // This command's own flags and the global ones, by name or declared alias, one hit per flag.
    let mut hits: Vec<(&str, &str)> = Vec::new();
    for arg in command.get_arguments().chain(cli.get_arguments()) {
        let Some(canonical) = arg.get_long() else { continue };
        let id = arg.get_id().as_str();
        let folds = fold(canonical) == want
            || arg.get_all_aliases().is_some_and(|all| all.iter().any(|a| fold(a) == want));
        if folds && !hits.iter().any(|(seen, _)| *seen == id) {
            hits.push((id, canonical));
        }
    }
    let name = command.get_name();
    if hits.len() > 1 {
        let flags =
            hits.iter().map(|(_, long)| format!("`--{long}`")).collect::<Vec<_>>().join(", ");
        let try_command = format!("{program} {name} --help");
        let message = format!(
            "--{long} is the spelling of {} flags {name} takes ({flags}), whose meanings differ, \
             so which you meant is not guessed. Name one. Try: {try_command}",
            hits.len()
        );
        let data = json!({
            "reason": "usage.ambiguous_flag",
            "flag": format!("--{long}"),
            "command": name,
            "couldBe": hits.iter().map(|(_, l)| format!("--{l}")).collect::<Vec<_>>(),
            "try": try_command,
        });
        let refusal = AppError::new(Code::Usage, "ambiguous_flag", message).with_data(data);
        return Some(Repair::Ambiguous(Box::new(refusal)));
    }
    let (_, canonical) = *hits.first()?;
    // Already the real spelling: clap refused it for another reason than its name.
    if canonical == long {
        return None;
    }
    let was = format!("--{long}");
    let now = format!("--{canonical}");
    let mut next = argv.to_vec();
    // Clap names the flag without its value, so `--onPermission=deny` is reported as
    // `--onPermission`: find the word by its flag part, and keep any value it carries.
    let at_token = next.iter().position(|a| {
        let word = a.to_string_lossy();
        word == token || word.strip_prefix(token).is_some_and(|rest| rest.starts_with('='))
    })?;
    let value = next[at_token].to_string_lossy().split_once('=').map(|(_, value)| value.to_owned());
    next[at_token] = match value {
        Some(value) => OsString::from(format!("{now}={value}")),
        None => OsString::from(&now),
    };
    Some(Repair::Took { argv: next, given: was, canonical: now })
}

/// `send`'s words `rest` with `--prompt-file FILE` taken out and the file read on stdin:
/// `acpmux send ... NAME - < FILE`. `None` when they carry prompt words too, which send would
/// send instead of stdin.
fn send_from_file(send: &clap::Command, rest: &[String], program: &str) -> Option<String> {
    let mut kept = Vec::new();
    let mut file = None;
    let mut positional = 0;
    let mut i = 0;
    while let Some(word) = rest.get(i) {
        if word == "--" {
            positional += rest.len() - i - 1;
            kept.extend(rest.get(i..).unwrap_or_default().iter().cloned());
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

    /// `repair`'s reading of `args`: the argv to run, the spelling given, the one it took.
    fn repaired(args: &[&str]) -> Option<(Vec<String>, String, String)> {
        let mut cli = crate::cli::command::Cli::command();
        let argv: Vec<OsString> =
            std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect();
        let e = cli.try_get_matches_from_mut(argv.clone()).err()?;
        let at = argv.iter().skip(1).position(|a| a != "--json").map(|i| i + 1)?;
        match repair(&e, &cli, &argv, at, "acpmux")? {
            Repair::Took { argv, given, canonical } => Some((
                argv.iter().map(|a| a.to_string_lossy().into_owned()).collect(),
                given,
                canonical,
            )),
            Repair::Ambiguous(_) => None,
        }
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

    /// A long flag no command takes is named, with this command's help, and never with a
    /// nearest spelling. Deliberately changed 2026-11-21: this used to assert the call fell
    /// through to clap, whose tip for `send --file` was the unrelated `--title`.
    #[test]
    fn a_flag_no_command_takes_is_named_with_this_command_s_help() {
        let e = refusal(&["send", "lane", "--no-such-flag"]).unwrap();
        let data = e.data.clone().unwrap();
        assert_eq!(data["reason"], "usage.unknown_flag", "{data}");
        assert_eq!(data["flag"], "--no-such-flag", "{data}");
        assert_eq!(data["takenBy"], json!([]), "{data}");
        assert_eq!(data["try"], "acpmux send --help", "{data}");
        assert!(e.message.ends_with("Try: acpmux send --help"), "{}", e.message);
        // A short flag has no case convention to read: clap's own error still.
        assert!(refusal(&["send", "lane", "-Z"]).is_none());
        assert!(refusal(&["--json", "send", "lane"]).is_none(), "parses");
    }

    /// The incident this page of work is named for. `acpmux send --file FILE` got clap's
    /// `tip: a similar argument exists: '--title'`, and `--title` is the title of a notice:
    /// following it would have been wrong. `send` has `--attach FILE` too, a third meaning.
    /// So `--file` must be refused honestly and never aliased to either.
    #[test]
    fn send_file_is_refused_and_never_read_as_title_or_attach() {
        let e = refusal(&["send", "--file", "/tmp/brief.md"]).unwrap();
        assert!(e.message.contains("--file"), "{}", e.message);
        assert!(!e.message.contains("--title"), "never the notice title: {}", e.message);
        assert!(!e.message.contains("--attach"), "never the attachment: {}", e.message);
        // And no fold reaches them either, so the call is never silently rerouted.
        assert!(repaired(&["send", "--file", "/tmp/brief.md"]).is_none());
    }

    /// Case and separators fold, so the call the caller meant runs.
    #[test]
    fn a_case_convention_spelling_is_read_as_the_flag_it_spells() {
        for given in ["--no_wait", "--noWait", "--NO-WAIT", "--nowait"] {
            let (argv, was, now) =
                repaired(&["send", "lane", given, "hi"]).unwrap_or_else(|| panic!("{given}"));
            assert_eq!(was, given, "names the spelling it took");
            assert_eq!(now, "--no-wait");
            assert!(argv.iter().any(|a| a == "--no-wait"), "{argv:?}");
            assert!(argv.iter().all(|a| a != given), "the given spelling is gone: {argv:?}");
        }
        // A value keeps its place, in both spellings.
        let (argv, _, now) = repaired(&["send", "lane", "--on_permission", "deny"]).unwrap();
        assert_eq!(now, "--on-permission");
        assert_eq!(argv.last().unwrap(), "deny");
        let (argv, _, _) = repaired(&["send", "lane", "--onPermission=deny"]).unwrap();
        assert!(argv.iter().any(|a| a == "--on-permission=deny"), "{argv:?}");
    }

    /// A fold is the whole name, so it never reaches a flag the caller did not spell: no
    /// prefix, no edit distance. These are near misses in clap's sense and misses in ours.
    #[test]
    fn a_near_spelling_is_not_a_fold_and_is_not_read() {
        for given in ["--no-wai", "--no-waiting", "--wait-no", "--attach-file", "--titl"] {
            assert!(repaired(&["send", "lane", given, "hi"]).is_none(), "{given}");
        }
    }

    /// The one place where failing is correct. Two real flags whose meanings differ must never
    /// be aliased together, so a spelling both answer to is refused naming each, never picked.
    /// Built on a parser of its own: a fold cannot collide two of acpmux's real flags today,
    /// and this must keep holding the day one could.
    #[test]
    fn a_spelling_two_real_flags_answer_to_is_refused_naming_both() {
        let command = clap::Command::new("acpmux").subcommand(
            clap::Command::new("post")
                // Two real flags, different meanings, same fold: inline text and a path.
                .arg(clap::Arg::new("body_file").long("body-file"))
                .arg(clap::Arg::new("bodyfile").long("bodyfile")),
        );
        let argv: Vec<OsString> =
            ["acpmux", "post", "--body_file", "/tmp/b"].iter().map(Into::into).collect();
        let e = command.clone().try_get_matches_from(argv.clone()).unwrap_err();
        let Some(Repair::Ambiguous(refusal)) = repair(&e, &command, &argv, 1, "acpmux") else {
            panic!("a spelling two real flags answer to must be refused, never picked");
        };
        let data = refusal.data.clone().unwrap();
        assert_eq!(data["reason"], "usage.ambiguous_flag", "{data}");
        assert_eq!(data["couldBe"], json!(["--body-file", "--bodyfile"]), "{data}");
        assert!(refusal.message.contains("`--body-file`"), "{}", refusal.message);
        assert!(refusal.message.contains("`--bodyfile`"), "{}", refusal.message);
        assert!(refusal.message.contains("not guessed"), "{}", refusal.message);
    }

    /// Purely additive: every spelling that worked before still parses, unrepaired.
    #[test]
    fn the_real_spellings_are_untouched() {
        for args in [
            ["send", "lane", "--no-wait"].as_slice(),
            ["send", "lane", "--on-permission", "deny"].as_slice(),
            ["send", "lane", "--attach", "/tmp/a.png"].as_slice(),
            ["send", "--notice", "--severity", "info", "--title", "t", "lane", "b"].as_slice(),
        ] {
            let mut cli = crate::cli::command::Cli::command();
            let argv: Vec<OsString> =
                std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect();
            assert!(cli.try_get_matches_from_mut(argv).is_ok(), "{args:?}");
        }
    }
}
