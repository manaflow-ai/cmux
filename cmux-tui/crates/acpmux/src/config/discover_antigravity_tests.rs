use super::*;

fn on_path(names: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
    move |name| names.contains(&name).then(|| format!("/opt/bin/{name}"))
}

/// Google Antigravity's `agy` CLI speaks ACP itself since 1.5 (`agy
/// acp`). On PATH it is the `antigravity` harness, so a NEXT chat can
/// start it without the ACP Registry's separate server.
#[test]
fn agy_on_path_runs_agy_acp() {
    let found = discover_harnesses_from(None, &on_path(&["agy"]));
    let agy = found.get("antigravity").expect("agy on PATH is a harness");
    assert_eq!(agy.kind, HarnessKind::Acp);
    assert_eq!(agy.argv, ["/opt/bin/agy", "acp"]);
    assert_eq!(crate::config::derive_family("antigravity", agy), "antigravity");
}

/// An `antigravity` the person imported from ~/.acpx stays theirs.
#[test]
fn antigravity_imported_from_acpx_stays_theirs() {
    let acpx = r#"{"agents": {"antigravity": {"argv": ["/Users/me/bin/my-agy", "acp"]}}}"#;
    let found = discover_harnesses_from(Some(acpx), &on_path(&["agy"]));
    assert_eq!(found["antigravity"].argv, ["/Users/me/bin/my-agy", "acp"]);
}
