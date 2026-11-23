//! `acpmux --help` against the docs and skills: every command they name
//! parses, and every command parses as documented. Split out of
//! `command.rs` to keep that file under 100 KB.

use super::Cli;
use clap::{CommandFactory, Parser};
use std::collections::{HashMap, HashSet};

const REMOTE_DOCS: &[(&str, &str)] = &[
    (
        "docs/remote-agents-and-cloud.md",
        include_str!("../../../../../docs/remote-agents-and-cloud.md"),
    ),
    ("acpmux README", include_str!("../../README.md")),
    ("acpmux skill", include_str!("../../skills/acpmux/SKILL.md")),
    ("integrate-harness skill", include_str!("../../skills/integrate-harness/SKILL.md")),
    ("cmux-acpmux skill", include_str!("../../../../../skills/cmux-acpmux/SKILL.md")),
    ("cmux skill", include_str!("../../../../../skills/cmux/SKILL.md")),
    ("cmux-computer-use skill", include_str!("../../../../../skills/cmux-computer-use/SKILL.md")),
    ("docs/agent-surfaces.md", include_str!("../../docs/agent-surfaces.md")),
    ("docs/cli-sessions.md", include_str!("../../docs/cli-sessions.md")),
    ("docs/cli-hosts.md", include_str!("../../docs/cli-hosts.md")),
    ("docs/cli-harnesses.md", include_str!("../../docs/cli-harnesses.md")),
    ("docs/cli-daemon.md", include_str!("../../docs/cli-daemon.md")),
    ("docs/cli-work.md", include_str!("../../docs/cli-work.md")),
];

fn shell_words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in text.chars() {
        if escaped {
            word.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            escaped = true;
            continue;
        }
        if let Some(closing) = quote {
            if character == closing {
                quote = None;
            } else {
                word.push(character);
            }
            continue;
        }
        match character {
            '\'' | '"' => quote = Some(character),
            ';' | '#' => break,
            character if character.is_whitespace() => {
                if !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
            }
            character => word.push(character),
        }
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
        .into_iter()
        .map(|word| word.trim_matches(|character| "`[]()<>.,:".contains(character)).to_owned())
        .collect()
}

fn tokens(text: &str, binary: &str) -> Vec<Vec<String>> {
    let mut snippets = Vec::new();
    let mut in_fence = false;
    for line in text.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence && (trimmed == binary || trimmed.starts_with(&format!("{binary} "))) {
            snippets.push(trimmed.to_owned());
        }
        let mut rest = line;
        while let Some(open) = rest.find('`') {
            let after_open = &rest[open + 1..];
            let Some(close) = after_open.find('`') else { break };
            let snippet = &after_open[..close];
            if snippet.trim_start() == binary
                || snippet.trim_start().starts_with(&format!("{binary} "))
            {
                snippets.push(snippet.trim().to_owned());
            }
            rest = &after_open[close + 1..];
        }
    }

    snippets
        .into_iter()
        .flat_map(|snippet| {
            snippet
                .split(';')
                .filter_map(|part| {
                    let words = shell_words(part.trim_start_matches("$ "));
                    (words.first().is_some_and(|word| word == binary) && words.len() > 1)
                        .then_some(words)
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

fn command_shapes() -> HashMap<Vec<String>, HashSet<String>> {
    fn visit(
        command: &clap::Command,
        path: &mut Vec<String>,
        shapes: &mut HashMap<Vec<String>, HashSet<String>>,
    ) {
        let mut flags = HashSet::new();
        for argument in command.get_arguments() {
            if let Some(long) = argument.get_long() {
                flags.insert(format!("--{long}"));
            }
            // A hidden alias (`--host` for `--machine`) still works, so docs may show it.
            for alias in argument.get_all_aliases().into_iter().flatten() {
                flags.insert(format!("--{alias}"));
            }
            if let Some(short) = argument.get_short() {
                flags.insert(format!("-{short}"));
            }
        }
        shapes.insert(path.clone(), flags);
        for subcommand in command.get_subcommands() {
            for name in std::iter::once(subcommand.get_name()).chain(subcommand.get_all_aliases()) {
                path.push(name.to_owned());
                visit(subcommand, path, shapes);
                path.pop();
            }
        }
    }

    let mut shapes = HashMap::new();
    visit(&Cli::command(), &mut Vec::new(), &mut shapes);
    for flags in shapes.values_mut() {
        flags.insert("--help".to_owned());
        flags.insert("-h".to_owned());
    }
    if let Some(flags) = shapes.get_mut(&Vec::new()) {
        flags.insert("--version".to_owned());
        flags.insert("-V".to_owned());
    }
    shapes
}

// The session guide also contains cmux app commands (such as `agent open-tab`).
// Only engine commands share this clap surface.
fn documented_engine_commands(text: &str) -> Vec<Vec<String>> {
    let mut commands = tokens(text, "acpmux");
    commands.extend(tokens(text, "cmux").into_iter().filter_map(|mut words| {
        match words.get(1)?.as_str() {
            "acp" => {}
            "agent"
                if !matches!(
                    words.get(2)?.as_str(),
                    "list"
                        | "message"
                        | "inbox"
                        | "start"
                        | "resume"
                        | "report"
                        | "hook"
                        | "plugin"
                        | "open"
                        | "open-tab"
                        | "help"
                        | "--help"
                ) => {}
            _ => return None,
        }
        words.remove(0);
        Some(words)
    }));
    commands
}

fn documented_shape(
    words: &[String],
    shapes: &HashMap<Vec<String>, HashSet<String>>,
) -> Option<Vec<String>> {
    let has_subcommands = |path: &[String]| {
        shapes.keys().any(|known| known.len() > path.len() && known.starts_with(path))
    };
    let mut start = 1;
    while words.get(start).is_some_and(|word| {
        matches!(word.as_str(), "--json" | "--suppress-reads" | "--help" | "--version")
    }) {
        start += 1;
    }
    if words.get(start).is_some_and(|word| !word.starts_with('-')) {
        let mut candidate = vec![words[start].clone()];
        if matches!(candidate[0].as_str(), "peer" | "host" | "hosts") {
            candidate[0] = "machine".to_owned();
        }
        if !candidate[0].split('|').any(|name| {
            let mut path = candidate.clone();
            path[0] = name.to_owned();
            shapes.keys().any(|known| known == &path)
        }) {
            return None;
        }
    }
    let command = words.iter().skip(start).take_while(|word| !word.starts_with('-'));
    let mut path = Vec::new();
    for word in command {
        let Some(candidate) = word.split('|').find(|candidate| {
            let candidate = if path.is_empty() && matches!(*candidate, "peer" | "host" | "hosts") {
                "machine"
            } else {
                candidate
            };
            let mut next = path.clone();
            next.push(candidate.to_owned());
            shapes.keys().any(|known| known == &next)
        }) else {
            // Once a command still has subcommands, an unknown word is a
            // stale verb rather than a positional argument.  Positional
            // values are allowed only after reaching a leaf command.
            if has_subcommands(&path) {
                return None;
            }
            break;
        };
        let candidate = if path.is_empty() && matches!(candidate, "peer" | "host" | "hosts") {
            "machine"
        } else {
            candidate
        };
        let mut next = path.clone();
        next.push(candidate.to_owned());
        path = next;
    }
    // A binary invocation containing only root flags (for example
    // `acpmux --version`) still belongs to the documented surface.
    Some(path)
}

#[test]
fn documented_acpmux_commands_and_flags_are_in_the_clap_surface() {
    let shapes = command_shapes();
    let mut missing = Vec::new();
    for (source, text) in REMOTE_DOCS {
        for words in documented_engine_commands(text) {
            let Some(path) = documented_shape(&words, &shapes) else {
                missing.push(format!("{source}: {} (command)", words.join(" ")));
                continue;
            };
            let mut flags = HashSet::new();
            flags.extend(
                shapes.get(&Vec::new()).into_iter().flat_map(|flags| flags.iter().cloned()),
            );
            for end in 1..=path.len() {
                flags.extend(
                    shapes.get(&path[..end]).into_iter().flat_map(|flags| flags.iter().cloned()),
                );
            }
            for word in words.iter().skip(1).filter(|word| word.starts_with('-')) {
                let flag = word.split('=').next().unwrap_or(word);
                if flag == "--" || flag == "-" || !flags.contains(flag) {
                    missing.push(format!("{source}: {} (flag {flag})", words.join(" ")));
                }
            }
        }
    }
    assert!(missing.is_empty(), "documented acpmux surface drifted:\n{}", missing.join("\n"));
}

/// The skills agents load teach the current names (`machine`, `machine pick`,
/// `machine dedicated`, `--machine`), not the hidden aliases kept for old scripts. The
/// acpmux skill's "Old spellings" bullet is the one place that names them.
#[test]
fn agent_skills_use_current_command_names() {
    const SKILLS: &[&str] = &[
        "acpmux skill",
        "integrate-harness skill",
        "cmux-acpmux skill",
        "cmux skill",
        "cmux-computer-use skill",
        "docs/agent-surfaces.md",
    ];
    let mut stale = Vec::new();
    for (source, text) in REMOTE_DOCS.iter().filter(|(source, _)| SKILLS.contains(source)) {
        let text: String = text
            .lines()
            .filter(|line| !line.trim_start().starts_with("- **Old spellings.**"))
            .map(|line| format!("{line}\n"))
            .collect();
        for words in documented_engine_commands(&text) {
            let command: Vec<&str> = words
                .iter()
                .skip(1)
                .map(String::as_str)
                .filter(|word| !word.starts_with('-'))
                .take(2)
                .collect();
            let old_verb =
                command.first().is_some_and(|verb| matches!(*verb, "host" | "hosts" | "peer"))
                    || command.get(1).is_some_and(|verb| matches!(*verb, "place" | "vm-host"));
            let old_flag = words.iter().any(|word| word.split('=').next() == Some("--host"));
            if old_verb || old_flag {
                stale.push(format!("{source}: {}", words.join(" ")));
            }
        }
    }
    assert!(
        stale.is_empty(),
        "a skill teaches an old acpmux spelling; use machine, machine pick, machine dedicated, \
         --machine:\n{}",
        stale.join("\n")
    );
}

/// `acpmux move-sessions` is `session move` spelled flat: both take `--machine` (`--host`)
/// and the same flags. The flat form had lost every `#[arg]`, so all nine fields became
/// positionals and `move-sessions CHAT --host H` failed with "HOST not provided".
#[test]
fn move_sessions_takes_the_same_flags_as_session_move() {
    use super::{Command, MoveSessionsArgs, flatten};
    let parse = |argv: &[&str]| Cli::try_parse_from(argv).map(|c| flatten(c.command.unwrap()));
    let want = MoveSessionsArgs {
        sessions: vec!["a".into(), "b".into()],
        host: Some("huge-blue".into()),
        all_idle: false,
        interrupt: true,
        after_turn: false,
        timeout: 600,
        leave_dirty: false,
        carry_changes: true,
        cwd: None,
        dry_run: true,
        from: Some("mini-3".into()),
        slow_ok: false,
        abort: false,
    };
    for verb in [&["move-sessions"][..], &["session", "move"][..]] {
        for machine in ["--machine", "--host"] {
            let argv: Vec<&str> = ["acpmux"]
                .into_iter()
                .chain(verb.iter().copied())
                .chain(["a", "b", machine, "huge-blue", "--interrupt", "--carry-changes"])
                .chain(["--dry-run", "--from", "mini-3"])
                .collect();
            match parse(&argv) {
                Ok(Command::MoveSessions(got)) => assert_eq!(got, want, "{argv:?}"),
                other => panic!("{argv:?} parsed as {:?}", other.map(|_| ()).err()),
            }
        }
        let idle: Vec<&str> = ["acpmux"]
            .into_iter()
            .chain(verb.iter().copied())
            .chain(["--all-idle", "--machine", "auto"])
            .collect();
        assert!(
            matches!(
                parse(&idle),
                Ok(Command::MoveSessions(MoveSessionsArgs { all_idle: true, .. }))
            ),
            "{idle:?}"
        );
        let no_machine: Vec<&str> =
            ["acpmux"].into_iter().chain(verb.iter().copied()).chain(["a"]).collect();
        assert!(parse(&no_machine).is_err(), "{no_machine:?} parsed without a machine");
    }
}

/// The class behind `move-sessions`' "HOST not provided": a command field with no `#[arg]`
/// is a positional, so a `bool` becomes a positional switch nobody can type and a value after
/// a list positional can never be reached. No command, hidden or shown, may have either: the
/// hidden flat forms (`tag-cmd`, `rules-cmd`, `limits-cmd`, `turn-cap-cmd`, `daemon-start`)
/// had them too, and clap refused to build their parsers at all.
#[test]
fn no_command_has_a_flag_shaped_positional_or_one_after_a_list() {
    use clap::CommandFactory as _;
    fn walk(cmd: &clap::Command, path: &str, bad: &mut Vec<String>) {
        let mut after_list: Option<String> = None;
        for arg in cmd.get_positionals() {
            let id = arg.get_id().to_string();
            if matches!(
                arg.get_action(),
                clap::ArgAction::SetTrue | clap::ArgAction::SetFalse | clap::ArgAction::Count
            ) {
                bad.push(format!("{path}: positional switch <{id}>"));
            }
            if let Some(list) = &after_list
                && !arg.is_last_set()
            {
                bad.push(format!("{path}: <{id}> follows the list <{list}>"));
            }
            if arg.get_num_args().is_some_and(|n| n.max_values() > 1) {
                after_list = Some(id);
            }
        }
        for sub in cmd.get_subcommands() {
            walk(sub, &format!("{path} {}", sub.get_name()), bad);
        }
    }
    let mut cmd = Cli::command();
    cmd.build();
    let mut bad = Vec::new();
    walk(&cmd, "acpmux", &mut bad);
    assert!(bad.is_empty(), "commands whose fields lost their #[arg]:\n{}", bad.join("\n"));
}

/// `send --class`: the four classes only (`prompt_class.rs`).
#[test]
fn send_class_takes_one_of_the_four_classes() {
    for class in crate::prompt_class::PromptClass::ALL {
        let argv = ["acpmux", "send", "coord", "done", "--class", class.as_str()];
        assert!(Cli::try_parse_from(argv).is_ok(), "{argv:?} did not parse");
    }
    assert!(Cli::try_parse_from(["acpmux", "send", "coord", "x", "--class", "urgent"]).is_err());
}

/// `--harness` is `-m` wherever a HARNESS[/MODEL] is asked for: `run --harness codex` starts
/// Codex instead of clap's guess `--harness-from`.
#[test]
fn harness_is_an_alias_of_model() {
    use super::{Command, flatten};
    let parse = |argv: &[&str]| Cli::try_parse_from(argv).map(|c| flatten(c.command.unwrap()));
    let run = parse(&["acpmux", "run", "lane", "--harness", "codex", "hi"]);
    assert!(matches!(run, Ok(Command::New(ref a)) if a.model.as_deref() == Some("codex")));
    let ensure = parse(&["acpmux", "ensure", "lane", "--harness", "claude/opus"]);
    assert!(matches!(
        ensure,
        Ok(Command::Ensure { ref model, .. }) if model.as_deref() == Some("claude/opus")
    ));
}

/// `session inbox`: --thread [--mark-read] reads the inbox's threads, --digest [--dry-run]
/// drains the queue's agent messages, and the two never mix; `send --pr | --thread`.
#[test]
fn session_inbox_reads_threads_or_drains_the_queue() {
    use super::{Command, SessionInboxTarget, flatten};
    let parse = |argv: &[&str]| Cli::try_parse_from(argv).map(|c| flatten(c.command.unwrap()));
    let threads = parse(&["acpmux", "session", "inbox", "c", "--thread", "pr:1", "--mark-read"]);
    assert!(matches!(
        threads,
        Ok(Command::SessionInboxCmd(SessionInboxTarget { ref thread, unread: true, .. }))
            if thread.as_deref() == Some("pr:1")
    ));
    let all = parse(&["acpmux", "session", "inbox", "c"]);
    assert!(matches!(all, Ok(Command::SessionInboxCmd(SessionInboxTarget { thread: None, .. }))));
    let subscribe = parse(&["acpmux", "session", "inbox", "c", "--subscribe", "pr:1"]);
    assert!(matches!(
        subscribe,
        Ok(Command::SessionInboxCmd(SessionInboxTarget { ref subscribe, .. }))
            if subscribe.as_deref() == Some("pr:1")
    ));
    let subscriptions = parse(&["acpmux", "session", "inbox", "c", "--subscriptions"]);
    assert!(matches!(
        subscriptions,
        Ok(Command::SessionInboxCmd(SessionInboxTarget { subscriptions: true, .. }))
    ));
    assert!(
        parse(&["acpmux", "session", "inbox", "c", "--subscribe", "t", "--thread", "u"]).is_err()
    );
    let digest = parse(&["acpmux", "session", "inbox", "c", "--digest"]);
    assert!(matches!(digest, Ok(Command::InboxDigest { dry_run: false, .. })));
    let dry = parse(&["acpmux", "session", "inbox", "c", "--dry-run"]);
    assert!(matches!(dry, Ok(Command::InboxDigest { dry_run: true, .. })));
    assert!(parse(&["acpmux", "session", "inbox", "c", "--thread", "t", "--digest"]).is_err());
    assert!(parse(&["acpmux", "session", "inbox", "c", "--mark-read"]).is_err());
    assert!(parse(&["acpmux", "send", "c", "x", "--pr", "12"]).is_ok());
    assert!(parse(&["acpmux", "send", "c", "x", "--thread", "rollout"]).is_ok());
    assert!(parse(&["acpmux", "send", "c", "x", "--pr", "12", "--thread", "t"]).is_err());
}

/// `send --notice`: --severity and --title with it, its other flags only with it.
#[test]
fn send_notice_takes_a_severity_and_a_title_and_its_flags_only_with_it() {
    use super::{Command, SendNotice, flatten};
    let parse = |argv: &[&str]| Cli::try_parse_from(argv).map(|c| flatten(c.command.unwrap()));
    let full = parse(&[
        "acpmux",
        "send",
        "coord",
        "body",
        "--notice",
        "--severity",
        "fire",
        "--title",
        "T",
        "--sender",
        "base-red-watch",
        "--host",
        "mini-3",
        "--link",
        "https://x.dev/pull/1=#1",
        "--link",
        "https://x.dev/run/2",
    ]);
    let Ok(Command::Send { notice, .. }) = full else { panic!("did not parse") };
    let SendNotice { notice, severity, title, sender, host, links } = *notice;
    assert!(notice);
    assert_eq!(severity.as_deref(), Some("fire"));
    assert_eq!(title.as_deref(), Some("T"));
    assert_eq!(sender.as_deref(), Some("base-red-watch"));
    assert_eq!(host.as_deref(), Some("mini-3"));
    assert_eq!(links, ["https://x.dev/pull/1=#1", "https://x.dev/run/2"]);
    for bad in [
        &["acpmux", "send", "c", "x", "--notice", "--title", "T"][..],
        &["acpmux", "send", "c", "x", "--notice", "--severity", "fire"][..],
        &["acpmux", "send", "c", "x", "--notice", "--severity", "loud", "--title", "T"][..],
        &["acpmux", "send", "c", "x", "--title", "T"][..],
        &["acpmux", "send", "c", "x", "--link", "https://x.dev"][..],
    ] {
        assert!(parse(bad).is_err(), "{bad:?} parsed");
    }
    assert!(parse(&["acpmux", "send", "c", "x"]).is_ok());
}

/// `machine dedicated [NAME] [on|off]` (old spelling `host vm-host`): the state is on or
/// off only.
#[test]
fn machine_dedicated_takes_a_machine_and_on_or_off() {
    for verb in [["machine", "dedicated"], ["host", "vm-host"], ["machine", "vm-host"]] {
        for rest in [&[][..], &["on"][..], &["cloud-a", "off"][..]] {
            let argv: Vec<&str> =
                ["acpmux"].into_iter().chain(verb).chain(rest.iter().copied()).collect();
            assert!(Cli::try_parse_from(&argv).is_ok(), "{argv:?} did not parse");
        }
        let argv: Vec<&str> =
            ["acpmux"].into_iter().chain(verb).chain(["cloud-a", "maybe"]).collect();
        assert!(Cli::try_parse_from(&argv).is_err(), "{argv:?} parsed");
    }
}

/// `host hold` changes a hold only for a named machine: a flag alone is refused, not
/// taken as the listing (review of #25602).
#[test]
fn host_hold_needs_a_name_to_change_anything() {
    for argv in [
        &["acpmux", "host", "hold", "--release"][..],
        &["acpmux", "host", "hold", "--reason", "x"][..],
        &["acpmux", "host", "hold", "--until", "2026-10-28T23:59:59Z"][..],
        &["acpmux", "host", "hold", "m", "--release", "--reason", "x"][..],
    ] {
        assert!(Cli::try_parse_from(argv).is_err(), "{argv:?} parsed");
    }
    for argv in [
        &["acpmux", "host", "hold"][..],
        &["acpmux", "host", "hold", "m", "--release"][..],
        &["acpmux", "host", "hold", "m", "--reason", "x", "--until", "2026-10-28T23:59:59Z"][..],
    ] {
        assert!(Cli::try_parse_from(argv).is_ok(), "{argv:?} did not parse");
    }
}

#[test]
fn peer_alias_still_parses_after_host_becomes_canonical() {
    let parsed = Cli::try_parse_from(["acpmux", "peer", "status"]);
    assert!(parsed.is_ok(), "peer alias stopped working");
}

#[test]
fn first_contact_host_key_trust_is_an_explicit_enroll_option() {
    for word in ["machine", "host", "hosts", "peer"] {
        let argv = ["acpmux", word, "enroll", "user@box", "--accept-new-host-key"];
        assert!(Cli::try_parse_from(argv).is_ok(), "{argv:?} did not parse");
        for verb in ["doctor", "setup", "update"] {
            let argv = ["acpmux", word, verb, "box", "--accept-new-host-key"];
            assert!(Cli::try_parse_from(argv).is_err(), "{argv:?} must not accept keys");
        }
        assert!(
            Cli::try_parse_from([
                "acpmux",
                word,
                "doctor",
                "box",
                "--fix",
                "--accept-new-host-key"
            ])
            .is_err()
        );
    }
}

/// docs/naming.md: `machine` is the command; `host`, `hosts` and `peer` stay hidden aliases
/// that parse to the same command, and `place` stays an alias of `pick`.
#[test]
fn machine_is_canonical_and_old_spellings_parse_the_same() {
    use super::{Command, PeerCmd};
    let top = Cli::command();
    let machine = top.find_subcommand("machine").expect("acpmux machine exists");
    let aliases: Vec<&str> = machine.get_all_aliases().collect();
    for old in ["host", "hosts", "peer"] {
        assert!(aliases.contains(&old), "{old} is not an alias of machine");
    }
    assert!(machine.get_visible_aliases().next().is_none(), "old spellings must stay hidden");
    for word in ["machine", "host", "hosts", "peer"] {
        for (verb, want_build) in [("pick", false), ("place", false), ("pick", true)] {
            let mut argv = vec!["acpmux", word, verb];
            if want_build {
                argv.push("--build");
            }
            match Cli::try_parse_from(&argv).map(|cli| cli.command) {
                Ok(Some(Command::Host(PeerCmd::Place { build }))) => {
                    assert_eq!(build, want_build, "{argv:?}")
                }
                _ => panic!("{argv:?} is not machine pick"),
            }
        }
        let argv = ["acpmux", word, "status"];
        assert!(
            matches!(
                Cli::try_parse_from(argv).map(|cli| cli.command),
                Ok(Some(Command::Host(PeerCmd::Status { .. })))
            ),
            "{argv:?} is not machine status"
        );
    }
}

/// `--machine` is the flag; `--host` stays a hidden alias (and `dispatch --target`), with the
/// same value grammar (`auto`, `auto-build`, `local`, NAME).
#[test]
fn machine_flag_and_host_alias_parse_the_same() {
    for flag in ["--machine", "--host"] {
        for value in ["auto", "auto-build", "local", "box"] {
            for argv in [
                vec!["acpmux", "new", flag, value, "-m", "claude", "hi"],
                vec!["acpmux", "ensure", "lane", flag, value],
                vec!["acpmux", "dispatch", "brief.md", flag, value],
                vec!["acpmux", "ls", flag, value],
                vec!["acpmux", "session", "move", "chat", flag, value],
                vec!["acpmux", "session", "start", "lane", flag, value],
            ] {
                assert!(Cli::try_parse_from(&argv).is_ok(), "{argv:?} did not parse");
            }
        }
    }
    assert!(Cli::try_parse_from(["acpmux", "dispatch", "brief.md", "--target", "box"]).is_ok());
    let help = Cli::command().find_subcommand_mut("new").unwrap().render_help().to_string();
    assert!(help.contains("--machine <MACHINE>"), "new --help does not show --machine:\n{help}");
    assert!(!help.contains("--host <"), "new --help still lists --host:\n{help}");
}

/// remote-ergo's fifth walk: "`acpmux daemon stop` fails with "unrecognized subcommand" and
/// no hint, but the command is `daemon shutdown`. Anyone who knows `session stop` will guess
/// "stop"."
#[test]
fn daemon_stop_is_daemon_shutdown_and_help_says_so() {
    use super::{Command, flatten};
    for (argv, want_end_agents) in [
        (&["acpmux", "daemon", "stop"][..], false),
        (&["acpmux", "daemon", "stop", "--end-agents"][..], true),
        (&["acpmux", "--json", "daemon", "stop", "--keep-agents"][..], false),
    ] {
        let cli = Cli::try_parse_from(argv).unwrap_or_else(|e| panic!("{argv:?}: {e}"));
        match cli.command.map(flatten) {
            Some(Command::Shutdown { end_agents, .. }) => {
                assert_eq!(end_agents, want_end_agents, "{argv:?}")
            }
            _ => panic!("{argv:?} is not daemon shutdown"),
        }
    }
    // `daemon --help` lists it on shutdown's line: `[aliases: stop]`.
    let help = Cli::command().find_subcommand_mut("daemon").unwrap().render_help().to_string();
    let line = help.lines().find(|l| l.trim_start().starts_with("shutdown")).unwrap();
    assert!(line.contains("stop]"), "daemon --help does not list the stop alias:\n{help}");
}

#[test]
fn stale_nested_command_is_rejected() {
    let shapes = command_shapes();
    let words = ["acpmux", "host", "statuz"].into_iter().map(str::to_owned).collect::<Vec<_>>();
    assert!(documented_shape(&words, &shapes).is_none());
}
