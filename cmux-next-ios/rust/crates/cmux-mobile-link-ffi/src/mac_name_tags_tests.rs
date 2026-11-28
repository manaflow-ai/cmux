//! Mirrors MacNameDisambiguationTests.swift: two Macs Aziz named alike must read apart, and a
//! unique name must read as before.

use super::*;

fn tags(macs: &[(&str, &str)]) -> HashMap<String, String> {
    mac_name_tags(
        macs.iter().map(|(id, name)| MacNameEntry { id: (*id).into(), name: (*name).into() }).collect(),
    )
}

fn tag<'a>(tags: &'a HashMap<String, String>, id: &str) -> Option<&'a str> {
    tags.get(id).map(String::as_str)
}

#[test]
fn unique_names_get_no_tag() {
    assert!(tags(&[("mac-1", "MacBook Pro"), ("mac-2", "Mac mini")]).is_empty());
}

#[test]
fn colliding_names_get_the_end_of_their_ids() {
    let t = tags(&[
        ("mac-0001-3f2a", "Aziz's MacBook Pro"),
        ("mac-0002-91c7", "Aziz's MacBook Pro"),
        ("mac-0003-aaaa", "Studio"),
    ]);
    assert_eq!(tag(&t, "mac-0001-3f2a"), Some("3F2A"));
    assert_eq!(tag(&t, "mac-0002-91c7"), Some("91C7"));
    assert_eq!(tag(&t, "mac-0003-aaaa"), None);
}

#[test]
fn case_and_surrounding_spaces_do_not_tell_names_apart() {
    let t = tags(&[("x-1111", "MacBook Pro"), ("y-2222", " macbook pro ")]);
    assert_eq!(tag(&t, "x-1111"), Some("1111"));
    assert_eq!(tag(&t, "y-2222"), Some("2222"));
}

#[test]
fn tag_grows_until_colliding_ids_differ() {
    let t = tags(&[("aa-9-beef", "Mac"), ("bb-8-beef", "Mac")]);
    assert_eq!(tag(&t, "aa-9-beef"), Some("9BEEF"));
    assert_eq!(tag(&t, "bb-8-beef"), Some("8BEEF"));
}

#[test]
fn the_same_mac_listed_twice_is_not_a_collision() {
    assert!(tags(&[("m-1234", "Mac"), ("m-1234", "Mac")]).is_empty());
}

#[test]
fn ids_that_never_differ_in_four_or_more_are_used_whole() {
    // Short ids: the whole cleaned id, uppercased.
    let t = tags(&[("ab", "Mac"), ("cd", "Mac")]);
    assert_eq!(tag(&t, "ab"), Some("AB"));
    assert_eq!(tag(&t, "cd"), Some("CD"));
    // One id ends the other: the longest length is used whole.
    let t = tags(&[("x-beef", "Mac"), ("1-x-beef", "Mac")]);
    assert_eq!(tag(&t, "x-beef"), Some("XBEEF"));
    assert_eq!(tag(&t, "1-x-beef"), Some("1XBEEF"));
}

#[test]
fn an_id_with_no_letters_or_digits_is_used_uppercased() {
    let t = tags(&[("--", "Mac"), ("a-1111", "Mac")]);
    assert_eq!(tag(&t, "--"), Some("--"));
    assert_eq!(tag(&t, "a-1111"), Some("1111"));
}

#[test]
fn settings_rows_example_reads_the_same() {
    let t = tags(&[
        ("8c41e0d2-3f2a", "Aziz's MacBook Pro"),
        ("5b97a6f1-91c7", "Aziz's MacBook Pro"),
        ("solo", "Studio"),
    ]);
    assert_eq!(tag(&t, "5b97a6f1-91c7"), Some("91C7"));
    assert_eq!(tag(&t, "8c41e0d2-3f2a"), Some("3F2A"));
    assert_eq!(tag(&t, "solo"), None);
}
