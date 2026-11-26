use super::*;

#[test]
fn unii_is_built_in_through_the_bundled_adapter() {
    let mut found = BTreeMap::new();
    add_uniichat(&mut found, Some(vec!["/App/bin/cmux".into(), "acp".into()]));
    let unii = &found[UNIICHAT_PROFILE];
    assert_eq!(unii.argv, vec!["/App/bin/cmux", "acp", "uniichat-agent"]);
    assert_eq!(unii.kind, HarnessKind::Acp);
    assert_eq!(unii.family.as_deref(), Some("unii"));
}

#[test]
fn a_unii_profile_file_still_wins() {
    let mut found = BTreeMap::new();
    add_uniichat(&mut found, Some(vec!["/a/acpmux".into()]));
    let mine = HarnessProfile { argv: vec!["/mine".into()], ..found[UNIICHAT_PROFILE].clone() };
    let mut found = BTreeMap::from([(UNIICHAT_PROFILE.to_owned(), mine.clone())]);
    add_uniichat(&mut found, Some(vec!["/a/acpmux".into()]));
    assert_eq!(found[UNIICHAT_PROFILE], mine);
}
