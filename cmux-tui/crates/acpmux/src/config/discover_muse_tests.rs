use super::*;

fn on_path(names: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
    move |name| names.contains(&name).then(|| format!("/opt/bin/{name}"))
}

/// With the adapter installed, `muse` is an ACP chat harness that runs
/// the adapter and hands it the `muse` it found; the terminal stays.
#[test]
fn muse_acp_makes_muse_an_acp_harness() {
    let found = discover_harnesses_from(None, &on_path(&["muse", "muse-acp"]));
    let muse = &found["muse"];
    assert_eq!(muse.kind, HarnessKind::Acp);
    assert_eq!(muse.argv, ["/opt/bin/muse-acp"]);
    assert_eq!(muse.env.get("MUSE_CLI").map(String::as_str), Some("/opt/bin/muse"));
    assert_eq!(muse.family.as_deref(), Some("muse"));
    let terminal = &found[MUSE_TERMINAL];
    assert_eq!(terminal.kind, HarnessKind::Terminal);
    assert_eq!(terminal.argv, ["/opt/bin/muse"]);
}

/// Without the adapter, `muse` stays the terminal harness it was.
#[test]
fn muse_without_the_adapter_stays_a_terminal_harness() {
    let found = discover_harnesses_from(None, &on_path(&["muse"]));
    assert_eq!(found["muse"].kind, HarnessKind::Terminal);
    assert!(!found.contains_key(MUSE_TERMINAL));
}

/// The adapter alone starts nothing: it needs Muse itself.
#[test]
fn the_adapter_without_muse_offers_nothing() {
    let found = discover_harnesses_from(None, &on_path(&["muse-acp"]));
    assert!(!found.contains_key("muse"));
}

/// A `muse` the person imported from ~/.acpx stays theirs.
#[test]
fn an_imported_muse_stays_theirs() {
    let acpx = r#"{"agents": {"muse": {"argv": ["/Users/me/bin/my-muse"]}}}"#;
    let found = discover_harnesses_from(Some(acpx), &on_path(&["muse", "muse-acp"]));
    assert_eq!(found["muse"].argv, ["/Users/me/bin/my-muse"]);
}
