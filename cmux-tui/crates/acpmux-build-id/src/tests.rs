#[test]
fn the_stamp_is_the_version_and_the_build_id_in_one_string() {
    let line = format!("{} ({})", env!("CARGO_PKG_VERSION"), super::build());
    assert_eq!(super::STAMP, format!("acpmux {line}"));
    assert_eq!(super::build(), env!("ACPMUX_BUILD"));
}
