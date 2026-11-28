use super::*;
use std::collections::HashMap;

fn graph(edges: &[(&str, &str)]) -> impl Fn(&str) -> Vec<String> {
    let mut by: HashMap<String, Vec<String>> = HashMap::new();
    for (waiter, target) in edges {
        by.entry((*target).to_owned()).or_default().push((*waiter).to_owned());
    }
    move |id| by.get(id).cloned().unwrap_or_default()
}

fn classes(c: &[(&str, Class)]) -> impl Fn(&str) -> Option<Class> {
    let m: HashMap<String, Class> = c.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect();
    move |id| m.get(id).copied()
}

#[test]
fn ranks_person_over_coordinators_over_lanes_over_batch() {
    assert!(Class::Person > Class::Interactive);
    assert!(Class::Interactive > Class::Coordinator);
    assert!(Class::Coordinator > Class::Lane);
    assert!(Class::Lane > Class::Batch);
}

#[test]
fn wire_values_round_trip_through_the_gateway_header() {
    for c in [Class::Interactive, Class::Coordinator, Class::Lane, Class::Batch] {
        assert_eq!(Class::parse(c.wire()), Some(c));
    }
    assert_eq!(Class::Person.wire(), "interactive");
    assert_eq!(Class::parse(" Background "), Some(Class::Lane));
    assert_eq!(Class::parse("urgent"), None);
}

#[test]
fn a_lane_nobody_waits_on_keeps_its_own_class() {
    let own = classes(&[("lane", Class::Lane)]);
    assert_eq!(inherited("lane", own, graph(&[])), Some(Class::Lane));
}

#[test]
fn a_lane_runs_at_its_waiters_class_through_a_chain() {
    // coord waits on lane, lane waits on its helper, a batch job waits on the helper too.
    let own = classes(&[
        ("coord", Class::Interactive),
        ("lane", Class::Lane),
        ("helper", Class::Lane),
        ("job", Class::Batch),
    ]);
    let waits = graph(&[("coord", "lane"), ("lane", "helper"), ("job", "helper")]);
    assert_eq!(inherited("helper", &own, &waits), Some(Class::Interactive));
    assert_eq!(inherited("lane", &own, &waits), Some(Class::Interactive));
    assert_eq!(inherited("coord", &own, &waits), Some(Class::Interactive));
}

#[test]
fn a_lower_waiter_never_lowers_a_session() {
    let own = classes(&[("coord", Class::Interactive), ("job", Class::Batch)]);
    assert_eq!(inherited("coord", own, graph(&[("job", "coord")])), Some(Class::Interactive));
}

#[test]
fn a_cycle_and_an_unknown_peer_end_cleanly() {
    let own = classes(&[("a", Class::Lane), ("b", Class::Lane), ("person", Class::Person)]);
    // a and b wait on each other; a peer's session (unclassed) waits on b, and a person
    // waits on that peer's session.
    let waits = graph(&[("a", "b"), ("b", "a"), ("peer", "b"), ("person", "peer")]);
    assert_eq!(inherited("a", own, waits), Some(Class::Person));
}

#[test]
fn a_chain_past_the_bound_stops_there() {
    let names: Vec<String> = (0..=MAX_DEPTH + 1).map(|i| format!("s{i}")).collect();
    let edges: Vec<(&str, &str)> =
        names.windows(2).map(|w| (w[1].as_str(), w[0].as_str())).collect();
    let top = names.last().unwrap().clone();
    let own = move |id: &str| Some(if id == top { Class::Person } else { Class::Lane });
    assert_eq!(inherited("s0", own, graph(&edges)), Some(Class::Lane));
}
