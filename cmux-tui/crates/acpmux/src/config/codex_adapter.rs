//! The pinned Codex ACP adapter package, and npx launches of adapter packages.

/// The codex-acp adapter version the cmux ACP installer pins. Discovery offers no npx launch of
/// it: an installed codex is the in-process bridge (`discover.rs`).
pub const CODEX_ACP_PACKAGE: &str = "@agentclientprotocol/codex-acp@1.10.0";

/// `[npx, -y, PACKAGE, ...]` (a config written that way): `(npx, PACKAGE)`.
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
