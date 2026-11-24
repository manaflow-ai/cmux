//! The intent layer (cmux-intent) against the real `acpmux` grammar.

use super::Cli;
use clap::CommandFactory;
use cmux_intent::{Kind, Repair, Table, repair};

fn fix(words: &[&str]) -> Repair {
    let words: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
    repair(&Cli::command().name("acpmux"), "acpmux", &words, &Table::embedded())
}

fn to(r: &Repair) -> Vec<&str> {
    r.argv.iter().map(String::as_str).collect()
}

#[test]
fn a_synonym_subcommand_runs() {
    let r = fix(&["inspect", "lane-1"]);
    assert_eq!(r.outcome, Kind::Ran, "{r:?}");
    assert_eq!(r.argv.get(1).map(String::as_str), Some("lane-1"), "{r:?}");
    assert!(["info", "status", "get", "show"].contains(&r.argv[0].as_str()), "{r:?}");
}

#[test]
fn a_mistyped_flag_runs() {
    let r = fix(&["info", "lane-1", "--feilds", "status"]);
    assert_eq!(r.outcome, Kind::Ran, "{r:?}");
    assert_eq!(to(&r), ["info", "lane-1", "--fields", "status"]);
}

#[test]
fn an_ambiguous_form_is_listed_or_the_best_read_runs() {
    let r = fix(&["show", "lane-1"]);
    match r.outcome {
        Kind::Candidates => assert!(r.candidates.len() >= 2, "{r:?}"),
        Kind::Ran => {
            assert!(r.candidates[0].notes.iter().any(|n| n.contains("read-only")), "{r:?}")
        }
        other => panic!("{other:?} {r:?}"),
    }
}

#[test]
fn a_destructive_form_with_a_typo_is_refused_with_its_exact_form() {
    let r = fix(&["archve", "lane-1"]);
    assert_eq!(r.outcome, Kind::Exact, "{r:?}");
    assert_eq!(to(&r), ["archve", "lane-1"]);
    assert_eq!(r.candidates[0].argv, ["archive", "lane-1"]);
}

#[test]
fn a_valid_form_is_untouched() {
    let r = fix(&["info", "lane-1"]);
    assert_eq!(r.outcome, Kind::Ok, "{r:?}");
}

#[test]
fn a_known_miss_machine_consent_status_does_not_guess_a_write() {
    let r = fix(&["machine", "consent", "status"]);
    assert!(matches!(r.outcome, Kind::None | Kind::Exact | Kind::Candidates), "{r:?}");
    assert!(
        r.outcome != Kind::Ran || r.argv.iter().all(|w| w != "grant" && w != "revoke"),
        "{r:?}"
    );
}

#[test]
fn a_known_miss_session_inbox_mark_read_needs_a_thread() {
    let r = fix(&["session", "inbox", "lane-1", "--mark-read"]);
    assert_eq!(r.outcome, Kind::None, "{r:?}");
}

/// What `acpmux ARGS` does when clap refuses it (entry.rs's `meant`), and its stderr.
fn parse_dead_end(args: &[&str]) -> (crate::cli::entry::Meant, String) {
    let mut grammar = Cli::command().name("acpmux").bin_name("acpmux");
    let argv: Vec<std::ffi::OsString> =
        std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect();
    let e = grammar.try_get_matches_from_mut(argv.clone()).expect_err("clap refuses it");
    let mut err = Vec::new();
    let meant = crate::cli::entry::meant(&e, &grammar, &argv, 1, "acpmux", &mut err);
    let said = String::from_utf8(err).unwrap();
    // The receipt for Leo's clause, in `cargo test -- --nocapture`.
    eprintln!("receipt: acpmux {} -> {said}", args.join(" "));
    (meant, said)
}

// Leo, 2026-11-23: "aka we need to be able to rewrite and correct their stuff", "aka not force yet
// another tool call": a clear, safe misspelling runs in the same call with one note.
#[test]
fn a_typo_of_ls_runs_ls_in_the_same_call_with_one_note() {
    let (meant, said) = parse_dead_end(&["lsit"]);
    let crate::cli::entry::Meant::Run(fixed) = meant else { panic!("nothing ran: {said}") };
    assert_eq!(fixed, ["ls"], "{said}");
    assert_eq!(said.lines().count(), 1, "{said}");
    assert!(said.starts_with("acpmux: ran `acpmux ls` for `acpmux lsit`"), "{said}");
}

#[test]
fn a_root_word_one_group_takes_runs_that_command_when_it_is_safe() {
    let (meant, said) = parse_dead_end(&["receipt", "msg-1"]);
    let crate::cli::entry::Meant::Run(fixed) = meant else { panic!("nothing ran: {said}") };
    assert_eq!(fixed, ["session", "receipt", "msg-1"], "{said}");
    assert_eq!(said.lines().count(), 1, "{said}");
}

#[test]
fn a_destructive_root_word_is_refused_with_its_exact_command() {
    let (meant, said) = parse_dead_end(&["restart", "lane-1"]);
    let crate::cli::entry::Meant::Refuse(refusal) = meant else { panic!("not refused: {said}") };
    assert!(refusal.message.contains("Try: acpmux session restart lane-1"), "{}", refusal.message);
    assert!(said.is_empty(), "{said}");
}

#[test]
fn a_destructive_typo_runs_nothing_and_names_the_exact_form() {
    let (meant, said) = parse_dead_end(&["archve", "lane-1"]);
    assert!(matches!(meant, crate::cli::entry::Meant::Clap), "{said}");
    assert!(said.contains("nothing ran: the exact form is needed"), "{said}");
    assert!(said.contains("acpmux archive lane-1"), "{said}");
}
