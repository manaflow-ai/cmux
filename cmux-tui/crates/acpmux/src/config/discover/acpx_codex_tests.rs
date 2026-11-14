use super::*;

fn which(name: &str) -> Option<String> {
    (name == "codex").then(|| "/opt/bin/codex".to_owned())
}

/// The cmux ACP installer's own codex-acp (an `~/.acpx` entry under
/// `~/.local/share/cmux-acp/`) gives way to the in-process bridge: it picked
/// another model than the config named and asked a second model to title every
/// chat (user 2026-10-20). It stays reachable as `codex-acp`.
#[test]
fn a_retired_cmux_acp_codex_import_gives_way_to_the_bridge() {
    let acpx = r#"{"agents": {"codex": {"argv": ["/Users/me/.local/share/cmux-acp/current/bin/codex-acp"]}}}"#;
    let found = discover_harnesses_from(Some(acpx), &which);
    assert_eq!(found["codex"].argv, ["/opt/bin/codex", "app-server"]);
    assert_eq!(found[CODEX_ACP].argv, ["/Users/me/.local/share/cmux-acp/current/bin/codex-acp"]);
}

/// An adapter of the person's own (anywhere else) stays `codex`.
#[test]
fn a_persons_own_codex_import_stays_theirs() {
    let acpx = r#"{"agents": {"codex": {"argv": ["/Users/me/bin/my-codex-adapter"]}}}"#;
    let found = discover_harnesses_from(Some(acpx), &which);
    assert_eq!(found["codex"].argv, ["/Users/me/bin/my-codex-adapter"]);
}
