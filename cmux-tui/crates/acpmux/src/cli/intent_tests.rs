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
    let r = fix(&["list"]);
    assert_eq!(r.outcome, Kind::Ran, "{r:?}");
    assert_eq!(to(&r), ["ls"]);
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
    let r = fix(&["stp", "lane-1"]);
    assert_eq!(r.outcome, Kind::Exact, "{r:?}");
    assert_eq!(to(&r), ["stp", "lane-1"]);
    assert_eq!(r.candidates[0].argv, ["stop", "lane-1"]);
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
