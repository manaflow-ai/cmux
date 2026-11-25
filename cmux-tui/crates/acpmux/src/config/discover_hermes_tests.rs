use super::*;

fn on_path(names: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
    move |name| names.contains(&name).then(|| format!("/opt/bin/{name}"))
}

/// Hermes Agent (NousResearch/hermes-agent) speaks ACP itself: `hermes
/// acp`. On PATH it is an ACP harness of its own family, so the Chief's
/// engine picker, `chief engine set --harness hermes` and chats can run it.
#[test]
fn hermes_on_path_runs_hermes_acp() {
    let found = discover_harnesses_from(None, &on_path(&["hermes"]));
    let hermes = found.get("hermes").expect("hermes on PATH is a harness");
    assert_eq!(hermes.kind, HarnessKind::Acp);
    assert_eq!(hermes.argv, ["/opt/bin/hermes", "acp"]);
    assert_eq!(crate::config::derive_family("hermes", hermes), "hermes");
}

/// A `hermes` the person imported from ~/.acpx stays theirs.
#[test]
fn hermes_imported_from_acpx_stays_theirs() {
    let acpx = r#"{"agents": {"hermes": {"argv": ["/Users/me/bin/my-hermes", "acp"]}}}"#;
    let found = discover_harnesses_from(Some(acpx), &on_path(&["hermes"]));
    assert_eq!(found["hermes"].argv, ["/Users/me/bin/my-hermes", "acp"]);
}
