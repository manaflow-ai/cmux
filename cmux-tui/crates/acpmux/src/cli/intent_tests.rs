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
            // One synonym that parses (`info`), or the best of several read-only forms.
            assert!(
                ["info", "status"].contains(&r.argv[0].as_str())
                    || r.candidates[0].notes.iter().any(|n| n.contains("read-only")),
                "{r:?}"
            )
        }
        other => panic!("{other:?} {r:?}"),
    }
}

#[test]
fn a_destructive_form_with_a_typo_is_refused_with_its_exact_form() {
    let r = fix(&["archiv", "lane-1"]);
    assert_eq!(r.outcome, Kind::Exact, "{r:?}");
    assert_eq!(to(&r), ["archiv", "lane-1"]);
    assert_eq!(r.candidates[0].argv, ["archive", "lane-1"]);
    // Close to both `archive` and `unarchive`: listed, and nothing runs.
    let r = fix(&["archve", "lane-1"]);
    assert!(matches!(r.outcome, Kind::Exact | Kind::Candidates), "{r:?}");
    assert_eq!(to(&r), ["archve", "lane-1"]);
    assert!(r.candidates.iter().any(|c| c.argv == ["archive", "lane-1"]), "{r:?}");
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

/// The acpmux forms clap refused on gcp-agent-lane-2 in the 7 days to 2026-11-25 (leo-workspace
/// `tools/cli_misses.py scan --since 7d`, hook refusals left out), as typed, ids made generic.
/// Before: every one was a refused call the agent then retried. The receipt prints what each does now.
const MEASURED: &[&[&str]] = &[
    &["bg", "output", "bg-1"],
    &["peers"],
    &["who-else", "--files", "a,b"],
    &["bg", "wait", "bg-1"],
    &["session", "inbox", "lane-1", "--mark-read"],
    &["session", "tags", "lane-1"],
    &["machine", "doctor", "--here"],
    &["who_else", "--topic", "x"],
    &["status", "host/lane-1"],
    &["peer", "list"],
    &["--host", "host-1", "info", "lane-1"],
    &["inbox", "read"],
    &["whoami"],
    &["session", "last", "host/lane-1"],
    &["machine", "exec", "host-1", "--", "sh", "-lc", "cmux version"],
    &["machines"],
    &["share-host", "status"],
    &["last", "host/lane-1"],
    &["process", "bg", "output", "bg-1"],
    &["tail", "lane-1"],
    &["send", "--dry-run", "host/lane-1", "readback"],
    &["session", "tail", "host/lane-1", "-n"],
    &["session", "inbox", "lane-1", "--thread", "t-1", "--mark-read"],
    &["last", "host/lane-1", "--inbox"],
    &["send_status"],
];

/// Weights: how many times each MEASURED form was refused in the 7 days.
const MEASURED_COUNT: &[usize] =
    &[6, 2, 2, 2, 2, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1];

/// What each MEASURED form that the layer runs must run: its meant form, never another read.
const MEANT: &[(&[&str], &[&str])] = &[
    (&["peer", "list"], &["peer", "ls"]),
    (&["who_else", "--topic", "x"], &["who-else", "--topic", "x"]),
];

#[test]
fn the_measured_refusals_run_only_their_meant_form() {
    assert_eq!(MEASURED.len(), MEASURED_COUNT.len());
    let (mut ran, mut parses, mut refused, mut total) = (0, 0, 0, 0);
    for (args, n) in MEASURED.iter().zip(MEASURED_COUNT) {
        total += n;
        let mut grammar = Cli::command().name("acpmux").bin_name("acpmux");
        let argv: Vec<std::ffi::OsString> =
            std::iter::once("acpmux").chain(args.iter().copied()).map(Into::into).collect();
        let Err(e) = grammar.try_get_matches_from_mut(argv) else {
            parses += n;
            eprintln!("receipt: acpmux {} -> parses as typed", args.join(" "));
            continue;
        };
        let r = fix(args);
        match r.outcome {
            Kind::Ran => {
                ran += n;
                eprintln!("receipt: acpmux {} -> ran {}", args.join(" "), r.argv.join(" "));
                let want = MEANT.iter().find(|(from, _)| from == args).map(|(_, to)| *to);
                assert_eq!(
                    Some(to(&r).as_slice()),
                    want,
                    "acpmux {} ran a form it did not mean: {e}",
                    args.join(" ")
                );
            }
            other => {
                refused += n;
                eprintln!("receipt: acpmux {} -> {other:?}, nothing ran", args.join(" "));
            }
        }
    }
    eprintln!(
        "receipt: of {total} refused calls, {parses} parse as typed, {ran} run their meant form, \
         {refused} still refused"
    );
    assert!(ran >= MEANT.len(), "{ran} of {total} ran; every MEANT form should");
}
