use super::*;
use crate::cli::command::Cli;
use clap::CommandFactory;
use std::collections::HashSet;

/// Every command a person sees in `--help`, by path; `""` is `acpmux`.
fn visible_paths(command: &Command, path: &mut Vec<String>, out: &mut Vec<String>) {
    out.push(path.join(" "));
    for sub in command.get_subcommands().filter(|sub| !sub.is_hide_set()) {
        path.push(sub.get_name().to_owned());
        visible_paths(sub, path, out);
        path.pop();
    }
}

fn all_visible() -> Vec<String> {
    let mut out = Vec::new();
    visible_paths(&Cli::command(), &mut Vec::new(), &mut out);
    out
}

/// A command line split the way a shell splits it, quotes removed.
fn shell_words(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut started = false;
    for c in line.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                started = true;
            }
            (None, c) if c.is_whitespace() => {
                if started || !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
                started = false;
            }
            (None, c) => word.push(c),
        }
    }
    if started || !word.is_empty() {
        words.push(word);
    }
    words
}

/// The subcommand path a parse reached (canonical names, aliases resolved).
fn parsed_path(matches: &clap::ArgMatches) -> String {
    let mut path = Vec::new();
    let mut at = matches;
    while let Some((name, sub)) = at.subcommand() {
        path.push(name.to_owned());
        at = sub;
    }
    path.join(" ")
}

/// A leaf's example runs that leaf; a group's runs the group or one of its commands.
fn runs(parsed: &str, key: &str) -> bool {
    key.is_empty() || parsed == key || parsed.starts_with(&format!("{key} "))
}

#[test]
fn every_visible_command_has_an_about_line_and_examples() {
    let mut missing = Vec::new();
    fn walk(command: &Command, path: &mut Vec<String>, missing: &mut Vec<String>) {
        let key = path.join(" ");
        if command.get_about().is_none() && command.get_long_about().is_none() && !key.is_empty() {
            missing.push(format!("acpmux {key}: no about line"));
        }
        if examples(&key).is_none_or(|e| e.is_empty()) && !has_own_examples(command) {
            missing.push(format!("acpmux {key}: no examples"));
        }
        for sub in command.get_subcommands().filter(|sub| !sub.is_hide_set()) {
            path.push(sub.get_name().to_owned());
            walk(sub, path, missing);
            path.pop();
        }
    }
    walk(&Cli::command(), &mut Vec::new(), &mut missing);
    assert!(
        missing.is_empty(),
        "add these to cli/help_examples (one entry per command path):\n{}",
        missing.join("\n")
    );
}

#[test]
fn every_example_entry_names_a_visible_command_once() {
    let visible: HashSet<String> = all_visible().into_iter().collect();
    let mut own = Vec::new();
    fn walk(command: &Command, path: &mut Vec<String>, own: &mut Vec<String>) {
        if has_own_examples(command) {
            own.push(path.join(" "));
        }
        for sub in command.get_subcommands() {
            path.push(sub.get_name().to_owned());
            walk(sub, path, own);
            path.pop();
        }
    }
    walk(&Cli::command(), &mut Vec::new(), &mut own);
    let mut seen = HashSet::new();
    let mut wrong = Vec::new();
    for (key, _) in GROUPS.iter().flat_map(|group| group.iter()) {
        if !visible.contains(*key) {
            wrong.push(format!("\"{key}\": no visible command has this path"));
        }
        if own.iter().any(|path| path == key) {
            wrong.push(format!("\"{key}\": its after-help has its own Examples:"));
        }
        if !seen.insert(*key) {
            wrong.push(format!("\"{key}\": listed twice"));
        }
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}

#[test]
fn every_example_parses_as_the_command_it_documents() {
    let mut wrong = Vec::new();
    for (key, list) in GROUPS.iter().flat_map(|group| group.iter()) {
        for (what, line) in *list {
            if what.trim().is_empty() {
                wrong.push(format!("\"{key}\": an example with no description: {line}"));
            }
            // Input piped in (`printf … | acpmux send coord -`) is fine; parse the acpmux part.
            let Some(at) = line.find("acpmux ").filter(|&at| at == 0 || line[..at].ends_with("| "))
            else {
                wrong.push(format!("\"{key}\": does not run acpmux: {line}"));
                continue;
            };
            let words = shell_words(&line[at..]);
            match Cli::command().try_get_matches_from(&words) {
                Ok(matches) => {
                    if let Err(e) = <Cli as clap::FromArgMatches>::from_arg_matches(&matches) {
                        wrong.push(format!("\"{key}\": {line}: {e}"));
                    } else if !runs(&parsed_path(&matches), key) {
                        wrong.push(format!(
                            "\"{key}\": {line}: runs `{}` instead",
                            parsed_path(&matches)
                        ));
                    }
                }
                Err(e) => wrong.push(format!("\"{key}\": {line}:\n{e}")),
            }
        }
    }
    assert!(wrong.is_empty(), "examples that do not parse:\n{}", wrong.join("\n"));
}

#[test]
fn help_shows_the_examples_after_the_options() {
    let mut grammar = attach(Cli::command());
    let session = grammar.find_subcommand_mut("session").expect("session");
    let help = session.find_subcommand_mut("cancel").expect("cancel").render_help().to_string();
    let examples_at = help.find("Examples:").expect("session cancel --help has Examples:");
    assert!(help.find("Options:").is_some_and(|options| options < examples_at), "{help}");
    // The root keeps its own after-help note and gains the examples below it.
    let root = attach(Cli::command()).render_help().to_string();
    let guide = root.find("acpmux guide").expect("root keeps the guide note");
    assert!(root.find("Examples:").is_some_and(|examples| guide < examples), "{root}");
}

#[test]
fn shell_words_keeps_quoted_text_together() {
    assert_eq!(
        shell_words(r#"acpmux send coord "fix the test" --class 'steer' """#),
        ["acpmux", "send", "coord", "fix the test", "--class", "steer", ""]
    );
}
