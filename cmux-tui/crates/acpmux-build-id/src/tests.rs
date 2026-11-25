#[test]
fn the_stamp_is_the_version_and_the_build_id_in_one_string() {
    let line = format!("{} ({})", env!("CARGO_PKG_VERSION"), super::build());
    assert_eq!(super::STAMP, format!("acpmux {line}"));
    assert_eq!(super::build(), env!("ACPMUX_BUILD"));
}

#[test]
fn the_commit_stamp_carries_the_commit_time() {
    assert_eq!(super::COMMIT_STAMP, format!("acpmux-commit-time={};", super::commit_time()));
    assert_eq!(super::commit_time().to_string(), env!("ACPMUX_COMMIT_TIME"));
}
