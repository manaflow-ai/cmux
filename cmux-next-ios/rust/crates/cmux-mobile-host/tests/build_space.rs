//! The host's build space: `CMUX_BUILD_SPACE` (or the older
//! `CMUX_MOBILE_BUILD_SPACE`), which the Mac app sets only for a dev build.
//! Unset is no build space; a blank, malformed or too-long value is refused
//! (the host does not start), never dropped into nightly's data.

use cmux_mobile_host::config::build_space_in;

fn var<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
    move |name| pairs.iter().find(|(k, _)| *k == name).map(|(_, v)| (*v).to_owned())
}

#[test]
fn a_dev_build_value_is_kept_under_either_name() {
    for name in ["CMUX_BUILD_SPACE", "CMUX_MOBILE_BUILD_SPACE"] {
        let space = build_space_in(var(&[(name, "dev:my-tag-2")])).unwrap().expect(name);
        assert_eq!(space.as_str(), "dev:my-tag-2");
    }
}

#[test]
fn unset_is_no_build_space() {
    assert_eq!(build_space_in(var(&[])).unwrap(), None);
}

#[test]
fn blank_malformed_and_too_long_values_are_refused() {
    let too_long = format!("dev:{}", "a".repeat(65));
    for value in ["", "  ", "my-tag", "dev:", "dev:My_Tag", "dev:-a", too_long.as_str()] {
        for name in ["CMUX_BUILD_SPACE", "CMUX_MOBILE_BUILD_SPACE"] {
            let error = build_space_in(var(&[(name, value)])).expect_err(value);
            assert!(error.to_string().contains("refusing to call cmux Cloud"), "{error}");
        }
    }
}

#[test]
fn two_names_that_disagree_are_refused() {
    let both = [("CMUX_BUILD_SPACE", "dev:a"), ("CMUX_MOBILE_BUILD_SPACE", "dev:b")];
    assert!(build_space_in(var(&both)).is_err());
}

#[test]
fn a_tagged_dev_launcher_without_a_space_is_refused() {
    let dev = [("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug.my-tag")];
    assert!(build_space_in(var(&dev)).is_err());
}
