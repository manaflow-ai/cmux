use super::*;
use std::path::{Path, PathBuf};

fn bundle(path: &Path) -> bool {
    path == Path::new("/App/bin/cmux-tui")
}

#[test]
fn chief_is_built_in_through_the_cmux_cli_beside_the_bundled_acpmux() {
    // The app bundle: `acpmux` and `cmux-tui` are links to one multicall binary.
    let mut found = BTreeMap::new();
    add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
    let chief = &found[CHIEF_PROFILE];
    assert_eq!(chief.argv, vec!["/App/bin/cmux-tui", "chief", "acp"]);
    assert_eq!(chief.kind, HarnessKind::Acp);
    assert_eq!(chief.family.as_deref(), Some(CHIEF_FAMILY));
    // `cmux-tui acp …`: the binary itself runs `chief acp`.
    let mut found = BTreeMap::new();
    add_chief(&mut found, Some((PathBuf::from("/opt/cmux-tui"), true)), &|_| false);
    assert_eq!(found[CHIEF_PROFILE].argv, vec!["/opt/cmux-tui", "chief", "acp"]);
}

#[test]
fn a_standalone_acpmux_without_the_cmux_cli_offers_no_chief_and_a_profile_file_wins() {
    let mut found = BTreeMap::new();
    add_chief(&mut found, Some((PathBuf::from("/usr/local/bin/acpmux"), false)), &|_| false);
    assert!(!found.contains_key(CHIEF_PROFILE), "never a `cmux` from PATH: {found:?}");
    let mine = HarnessProfile {
        argv: vec!["/mine".into()],
        kind: HarnessKind::Acp,
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut found = BTreeMap::from([(CHIEF_PROFILE.to_owned(), mine.clone())]);
    add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
    assert_eq!(found[CHIEF_PROFILE], mine);
}

#[test]
fn the_chief_is_never_the_automatic_default_harness() {
    // `chief` sorts before `claude`: with no configured default, every new chat on a Mac
    // would start on the person's Chief (seen in the fleet capture, 2026-10-30).
    let mut found = BTreeMap::new();
    add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
    let mut claude = found[CHIEF_PROFILE].clone();
    claude.argv = vec!["claude".into()];
    claude.family = Some("claude".into());
    found.insert("claude".into(), claude);
    let mut cfg = crate::config::Config::default();
    cfg.join_discovered(found.clone());
    cfg.pick_auto_default_for_tests();
    assert_eq!(cfg.default_harness.as_deref(), Some("claude"));
    // With the Chief alone there is no automatic default at all.
    let mut alone = crate::config::Config::default();
    found.remove("claude");
    alone.join_discovered(found);
    alone.pick_auto_default_for_tests();
    assert_eq!(alone.default_harness, None);
}

#[test]
fn the_chief_harness_draws_the_ch_monogram_not_a_picture() {
    let mut found = BTreeMap::new();
    add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
    let profile = &found[CHIEF_PROFILE];
    let spec = crate::config::harness_icon::resolve(
        CHIEF_PROFILE,
        Some("Chief"),
        profile,
        CHIEF_FAMILY,
        None,
    );
    let crate::config::harness_icon::IconSpec::Monogram { text, .. } = spec else {
        panic!("{spec:?}")
    };
    assert_eq!(text, "CH");
}
