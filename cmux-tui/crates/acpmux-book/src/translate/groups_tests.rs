use std::collections::HashMap;

use super::groups::{Class, Group, RunKind, display_groups};

#[derive(serde::Deserialize)]
struct Call {
    class: String,
}

#[derive(serde::Deserialize)]
struct Case {
    name: String,
    entries: Vec<String>,
    groups: Vec<Vec<String>>,
}

#[derive(serde::Deserialize)]
struct Cases {
    calls: HashMap<String, Call>,
    cases: Vec<Case>,
}

fn class(name: &str) -> Class {
    let run = |kind| Class::Run { kind, diff: false };
    match name {
        "thought" => Class::Thought,
        "commands" => run(RunKind::Commands),
        "reads" => run(RunKind::Reads),
        "edits" => run(RunKind::Edits),
        "edits+diff" => Class::Run { kind: RunKind::Edits, diff: true },
        "searches" => run(RunKind::Searches),
        "subsession-start" => Class::SubsessionStart,
        "sent" => Class::Sent { parts: 1 },
        "card" => Class::Card,
        "plain" => Class::Plain,
        other => Class::Mcp(other.strip_prefix("mcp:").expect(other).to_owned()),
    }
}

fn drawn(group: &Group, ids: &[&str]) -> Vec<String> {
    let kind = match group {
        Group::Run { kind, .. } => format!("run:{}", format!("{kind:?}").to_lowercase()),
        Group::Item(_) => "item".into(),
        Group::Mcp(_) => "mcp".into(),
        Group::Subsessions(_) => "subsessionGroup".into(),
        Group::Card(_) => "card".into(),
        Group::Sent(_) => "sent".into(),
        Group::SentRun(_) => "sentGroup".into(),
    };
    std::iter::once(kind).chain(group.items().iter().map(|&at| ids[at].to_owned())).collect()
}

#[test]
fn the_shared_display_group_cases_are_the_daemons_rule() {
    let cases: Cases =
        serde_json::from_str(include_str!("fixtures/display-groups-cases.json")).unwrap();
    assert!(cases.cases.len() > 20);
    for case in cases.cases {
        let (ids, classes): (Vec<&str>, Vec<Class>) = case
            .entries
            .iter()
            .map(|entry| {
                let (id, call) = entry.split_once(':').unwrap();
                let name = if call == "thought" { "thought" } else { &cases.calls[call].class };
                (id, class(name))
            })
            .unzip();
        let groups: Vec<Vec<String>> =
            display_groups(&classes).iter().map(|group| drawn(group, &ids)).collect();
        assert_eq!(groups, case.groups, "{}", case.name);
    }
}

#[test]
fn a_call_that_sent_a_batch_is_a_sent_group_of_one_call() {
    let groups = display_groups(&[Class::Sent { parts: 3 }, Class::Plain]);
    assert_eq!(groups, vec![Group::SentRun(vec![0]), Group::Item(1)]);
}

#[test]
fn a_group_is_known_by_its_first_call_not_the_thought_that_led_it() {
    let classes = [Class::Thought, class("commands"), class("commands")];
    let groups = display_groups(&classes);
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0].id(&classes), 1);
}

#[test]
fn every_entry_draws_once_in_order() {
    let names = [
        "thought",
        "commands",
        "reads",
        "edits",
        "edits+diff",
        "searches",
        "mcp:a",
        "mcp:b",
        "subsession-start",
        "sent",
        "card",
        "plain",
    ];
    // Every pair and triple of classes: no entry lost, none twice (a batch's call aside).
    for a in names {
        for b in names {
            for c in names {
                let classes = [class(a), class(b), class(c)];
                let seen: Vec<usize> =
                    display_groups(&classes).iter().flat_map(|g| g.items().to_vec()).collect();
                let mut expected: Vec<usize> = (0..3).collect();
                if a == "thought" && b == "thought" {
                    expected.retain(|&at| at != 1);
                }
                if b == "thought" && c == "thought" {
                    expected.retain(|&at| at != 2);
                }
                assert_eq!(seen, expected, "{a} {b} {c}");
            }
        }
    }
}
