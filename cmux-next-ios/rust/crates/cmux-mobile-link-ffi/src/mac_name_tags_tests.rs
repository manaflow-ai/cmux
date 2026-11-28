//! Mirrors MacNameDisambiguationTests.swift: Macs that share a name read apart by their id's end.

use super::*;

fn tags(macs: &[(&str, &str)]) -> HashMap<String, String> {
    mac_name_tags(
        macs.iter().map(|(id, name)| MacNameInput { id: (*id).into(), name: (*name).into() }).collect(),
    )
    .into_iter()
    .map(|t| (t.id, t.tag))
    .collect()
}

#[test]
fn unique_names_get_no_tag() {
    assert!(tags(&[("a1b2c3d4", "Aziz's Mac Studio"), ("e5f6a7b8", "Aziz's MacBook Pro")]).is_empty());
}

#[test]
fn colliding_names_are_tagged_by_id_ending() {
    let t = tags(&[
        ("mac-0001-3f2a", "Aziz's MacBook Pro"),
        ("mac-0002-91c7", "Aziz's MacBook Pro"),
        ("mac-0003-aaaa", "Aziz's Mac Studio"),
    ]);
    assert_eq!(t.get("mac-0001-3f2a").map(String::as_str), Some("3F2A"));
    assert_eq!(t.get("mac-0002-91c7").map(String::as_str), Some("91C7"));
    assert_eq!(t.get("mac-0003-aaaa"), None);
}

#[test]
fn case_and_spaces_do_not_hide_a_collision() {
    let t = tags(&[("x-1111", "MacBook Pro"), ("y-2222", " macbook pro ")]);
    assert_eq!(t["x-1111"], "1111");
    assert_eq!(t["y-2222"], "2222");
}

#[test]
fn tag_grows_until_colliding_ids_differ() {
    let t = tags(&[("aa-9-beef", "Mac"), ("bb-8-beef", "Mac")]);
    assert_eq!(t["aa-9-beef"], "9BEEF");
    assert_eq!(t["bb-8-beef"], "8BEEF");
}

#[test]
fn the_same_mac_listed_twice_is_not_a_collision() {
    assert!(tags(&[("m-1234", "Mac"), ("m-1234", "Mac")]).is_empty());
}

#[test]
fn account_scope_tags_a_mac_whose_namesake_is_in_another_team() {
    // Swift flattens every team's Macs into one list before tagging.
    let t = tags(&[("aaaa-3f2a", "MacBook Pro"), ("bbbb-91c7", "MacBook Pro")]);
    assert_eq!(t["aaaa-3f2a"], "3F2A");
    assert_eq!(t["bbbb-91c7"], "91C7");
}

#[test]
fn a_short_or_symbol_only_id_is_used_whole() {
    let t = tags(&[("ab", "Mac"), ("--", "Mac")]);
    assert_eq!(t["ab"], "AB");
    assert_eq!(t["--"], "--");
}

#[test]
fn identical_endings_past_the_longest_id_stay_whole() {
    // Ids equal after cleaning ("a-1" and "a1") never differ: each keeps its whole cleaned form.
    let t = tags(&[("a-1", "Mac"), ("a1", "Mac")]);
    assert_eq!(t["a-1"], "A1");
    assert_eq!(t["a1"], "A1");
}
