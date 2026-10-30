//! Chief makes too many sidebar groups (a teammate's complaint; Lawrence's
//! sidebar, Oct 27: 37 groups, 14 of the 32 Chief used in a week used once):
//! a `Group:` line that is close to an existing group ("Perf" beside
//! "Performance", "Sidebar" beside "Sidebar & tabs") made a new one, and a
//! long line made a group named after a sentence. The host now reuses the
//! existing group a name matches and trims a long name to its topic.

use optchat_chief::workspaces::{GroupChoice, group_choice};

const EXISTING: &[&str] = &[
    "Home & chat",
    "Agents & routing",
    "Sidebar & tabs",
    "Panes & layout",
    "Performance",
    "Browser & parity",
    "Nightly & CI",
    "Cloud & fleet",
    "iOS & mobile",
    "cmux-next app",
    "Security audit",
    "Accounts & billing",
];

fn existing() -> Vec<String> {
    EXISTING.iter().map(|s| s.to_string()).collect()
}

#[test]
fn a_name_that_matches_a_group_reuses_it() {
    for (asked, want) in [
        ("Sidebar & tabs", "Sidebar & tabs"),
        ("sidebar & TABS", "Sidebar & tabs"),
        ("Sidebar", "Sidebar & tabs"),
        ("Tabs", "Sidebar & tabs"),
        ("Panes", "Panes & layout"),
        ("Perf", "Performance"),
        ("performance", "Performance"),
        ("iOS", "iOS & mobile"),
        ("iOS apps", "iOS & mobile"),
        ("Security", "Security audit"),
        ("Browser", "Browser & parity"),
        ("Cloud", "Cloud & fleet"),
        ("Billing & cloud", "Accounts & billing"),
        ("Chief/Home", "Home & chat"),
    ] {
        assert_eq!(
            group_choice(asked, &existing()),
            GroupChoice::Existing(want.to_owned()),
            "asked {asked:?}"
        );
    }
}

#[test]
fn a_name_like_no_group_makes_a_new_one() {
    for asked in ["Vault", "Onboarding", "Terminals", "Crashes & QA"] {
        assert_eq!(
            group_choice(asked, &existing()),
            GroupChoice::New(asked.to_owned()),
            "asked {asked:?}"
        );
    }
}

#[test]
fn a_long_name_is_trimmed_to_its_topic_before_it_is_matched() {
    // A task's group line that ran on (Lawrence's sidebar has this group).
    let asked = "Agents & routing. Repos ~/fun/cmuxterm-hq (PR to main, merge when green, staging";
    assert_eq!(
        group_choice(asked, &existing()),
        GroupChoice::Existing("Agents & routing".to_owned())
    );
    let asked = "Notes app. It lives in ~/fun/notes, ship it today";
    assert_eq!(
        group_choice(asked, &existing()),
        GroupChoice::New("Notes app".to_owned())
    );
}

#[test]
fn a_shared_word_alone_is_no_match() {
    // "app" is in "cmux-next app"; "audit" in "Security audit": too weak alone.
    assert_eq!(
        group_choice("Chief app audit", &existing()),
        GroupChoice::New("Chief app audit".to_owned())
    );
}

#[test]
fn a_shared_second_word_prefers_the_group_named_by_that_topic_first() {
    // Lawrence's sidebar has both: "Cloud" belongs with "Cloud & fleet", not
    // "Billing & cloud", whose topic is billing.
    let groups: Vec<String> = ["Billing & cloud", "Cloud & fleet", "Accounts & billing"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(
        group_choice("Cloud", &groups),
        GroupChoice::Existing("Cloud & fleet".to_owned())
    );
    // Either billing group is right for "Billing"; it must not make a third one.
    assert!(matches!(
        group_choice("Billing", &groups),
        GroupChoice::Existing(_)
    ));
}
