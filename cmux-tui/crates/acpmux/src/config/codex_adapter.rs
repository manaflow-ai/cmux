//! Codex without its ACP adapter on PATH: run the pinned adapter package through npx.

use std::collections::BTreeMap;

use super::{HarnessKind, HarnessProfile};

/// The codex-acp adapter version acpmux runs when only `codex` is installed (the version the
/// cmux ACP installer pins).
pub const CODEX_ACP_PACKAGE: &str = "@agentclientprotocol/codex-acp@1.10.0";

/// A `codex` harness through `npx -y <CODEX_ACP_PACKAGE>`, the adapter pointed at the installed
/// codex by CODEX_PATH; None unless both codex and npx are found.
pub fn codex_through_adapter_package(
    codex: Option<&str>,
    npx: Option<&str>,
) -> Option<HarnessProfile> {
    let (codex, npx) = (codex?, npx?);
    Some(HarnessProfile {
        kind: HarnessKind::Acp,
        argv: vec![npx.to_owned(), "-y".into(), CODEX_ACP_PACKAGE.into()],
        env: BTreeMap::from([("CODEX_PATH".to_owned(), codex.to_owned())]),
        description: Some(format!("Codex through {CODEX_ACP_PACKAGE} (no codex-acp on PATH)")),
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    })
}
