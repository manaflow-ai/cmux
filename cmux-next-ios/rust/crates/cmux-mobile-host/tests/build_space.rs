//! `CMUX_MOBILE_BUILD_SPACE`: the Mac app sets it only for a dev build; an
//! unset, blank or malformed value is no build space (no header sent).

use cmux_mobile_host::config::build_space_from;

#[test]
fn a_dev_build_value_is_kept() {
    let space = build_space_from(Some("dev:my-tag-2")).expect("a valid value");
    assert_eq!(space.as_str(), "dev:my-tag-2");
}

#[test]
fn unset_blank_and_malformed_values_send_nothing() {
    for value in
        [None, Some(""), Some("  "), Some("my-tag"), Some("dev:"), Some("dev:My_Tag"), Some("dev:-a")]
    {
        assert_eq!(build_space_from(value), None, "{value:?}");
    }
    let too_long = format!("dev:{}", "a".repeat(65));
    assert_eq!(build_space_from(Some(&too_long)), None);
}
