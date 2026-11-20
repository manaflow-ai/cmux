//! The `Examples:` section of every visible command's `--help`. The examples
//! live in tables here, one file per command group, keyed by the command's
//! path (`"session cancel"`; `""` is `acpmux` itself), so the grammar in
//! `command.rs` stays readable. `attach` adds them to the clap tree that
//! `entry` parses with; a command whose after-help has its own `Examples:`
//! (`ls`) needs no entry. The tests fail on a visible command without an about
//! line or examples, on an example for a command that is gone, and on an
//! example that does not parse.

use clap::Command;

mod daemon;
mod harness;
mod host;
mod session;
mod top;
mod work;

/// One example: what it does, then the command line, starting `acpmux `.
pub(crate) type Example = (&'static str, &'static str);

const GROUPS: &[&[(&str, &[Example])]] = &[
    top::EXAMPLES,
    work::EXAMPLES,
    session::EXAMPLES,
    host::EXAMPLES,
    harness::EXAMPLES,
    daemon::EXAMPLES,
];

fn examples(path: &str) -> Option<&'static [Example]> {
    GROUPS.iter().flat_map(|group| group.iter()).find(|(key, _)| *key == path).map(|(_, e)| *e)
}

/// A command whose own after-help already has an `Examples:` section (`ls`) keeps it alone.
fn has_own_examples(command: &Command) -> bool {
    command.get_after_help().is_some_and(|text| text.to_string().contains("Examples:"))
}

fn render(examples: &[Example]) -> String {
    let mut text = String::from("Examples:");
    for (what, line) in examples {
        text.push_str(&format!("\n  # {what}\n  {line}"));
    }
    text
}

/// The grammar with each command's examples after its help.
pub(crate) fn attach(command: Command) -> Command {
    attach_at(command, &mut Vec::new())
}

fn attach_at(mut command: Command, path: &mut Vec<String>) -> Command {
    if let Some(examples) = examples(&path.join(" ")).filter(|_| !has_own_examples(&command)) {
        let text = match command.get_after_help() {
            Some(before) => format!("{before}\n\n{}", render(examples)),
            None => render(examples),
        };
        command = command.after_help(text);
    }
    let names: Vec<String> =
        command.get_subcommands().map(|sub| sub.get_name().to_owned()).collect();
    for name in names {
        path.push(name.clone());
        command = command.mut_subcommand(name, |sub| attach_at(sub, path));
        path.pop();
    }
    command
}

#[cfg(test)]
mod tests;
