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

/// `[npx, -y, PACKAGE, ...]` (the pinned adapter launch above, or a config
/// written the same way): `(npx, PACKAGE)`.
pub fn adapter_package_launch(argv: &[String]) -> Option<(&str, &str)> {
    let [npx, yes, package, ..] = argv else { return None };
    let is_npx = std::path::Path::new(npx).file_name().is_some_and(|n| n == "npx");
    (is_npx && yes == "-y" && !package.starts_with('-') && package_bin(package).is_some())
        .then_some((npx.as_str(), package.as_str()))
}

/// The bin a package installs under its own name: `@scope/name@1.2` and
/// `name@1.2` give `name`. Only a plain name, since it goes into `npx -c`.
fn package_bin(package: &str) -> Option<&str> {
    if package.starts_with('@') && !package.contains('/') {
        return None;
    }
    let name = package.rsplit('/').next()?.split('@').next()?;
    let plain = !name.is_empty()
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'));
    plain.then_some(name)
}

/// The installed bin of `package` in npx's cache, installing it when
/// needed: `npx -y -p PACKAGE -c 'command -v NAME'`. Run once per package
/// off the switch path, so no spawn waits on npx (3.6 to 21 s measured).
pub async fn resolve_adapter_package_bin(npx: &str, package: &str) -> Option<String> {
    let bin = package_bin(package)?;
    let mut cmd = tokio::process::Command::new(npx);
    crate::login_env::apply_tokio(&mut cmd);
    cmd.args(["-y", "-p", package, "-c", &format!("command -v {bin}")])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    // An install from the registry can take a while; a hung npx cannot.
    let out =
        tokio::time::timeout(std::time::Duration::from_secs(120), cmd.output()).await.ok()?.ok()?;
    if !out.status.success() {
        return None;
    }
    let path = String::from_utf8(out.stdout).ok()?.lines().last()?.trim().to_owned();
    let p = std::path::Path::new(&path);
    (p.is_absolute() && p.is_file()).then_some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_launches_and_their_bin_names() {
        let argv = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            adapter_package_launch(&argv(&["/usr/bin/npx", "-y", CODEX_ACP_PACKAGE])),
            Some(("/usr/bin/npx", CODEX_ACP_PACKAGE))
        );
        assert_eq!(package_bin(CODEX_ACP_PACKAGE), Some("codex-acp"));
        assert_eq!(package_bin("plain@2"), Some("plain"));
        assert_eq!(package_bin("@scope"), None);
        assert_eq!(package_bin("@s/x;rm -rf ~"), None);
        assert!(adapter_package_launch(&argv(&["/usr/bin/node", "-y", "x"])).is_none());
        assert!(adapter_package_launch(&argv(&["npx", "x"])).is_none());
    }
}
