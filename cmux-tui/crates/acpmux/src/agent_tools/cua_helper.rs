//! Installed helper discovery for a DEV app with no bundled client.

use std::path::{Path, PathBuf};

#[cfg(any(target_os = "macos", test))]
const HELPER_APP: &str = "cmux Computer Use.app";
#[cfg(any(target_os = "macos", test))]
const HELPER_BINARY: &str = "Contents/MacOS/cmux-cua";
// Keep equal to CuaHelperIdentity.requirement in CmuxNextAgentActivity.
#[cfg(target_os = "macos")]
const REQUIREMENT: &str = concat!(
    "identifier \"com.cmuxterm.cua\" and anchor apple generic",
    " and certificate 1[field.1.2.840.113635.100.6.2.6]",
    " and certificate leaf[field.1.2.840.113635.100.6.1.13]",
    " and certificate leaf[subject.OU] = \"7WLXT3NR37\"",
);

pub(super) fn installed(exe: &Path) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        find(
            exe,
            || {
                let mut roots = vec![PathBuf::from("/Applications")];
                roots.extend(dirs::home_dir().map(|home| home.join("Applications")));
                roots
            },
            verified_once,
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = exe;
        None
    }
}

// The roots and checker are injected so tests use no installed apps.
#[cfg(any(target_os = "macos", test))]
pub(super) fn find(
    exe: &Path,
    roots: impl FnOnce() -> Vec<PathBuf>,
    mut is_signed: impl FnMut(&Path) -> bool,
) -> Option<PathBuf> {
    let app = exe.ancestors().find(|path| path.extension().is_some_and(|ext| ext == "app"))?;
    let info = plist::Value::from_file(app.join("Contents/Info.plist")).ok()?;
    let bundle_id = info.as_dictionary()?.get("CFBundleIdentifier")?.as_string()?;
    if !bundle_id.contains(".debug") {
        return None;
    }
    // Match CuaHelperIdentity.installedCandidates(isDevBuild: true), including
    // the standalone helper after the three cmux apps in each root.
    for root in roots() {
        let candidates = ["cmux NIGHTLY.app", "cmux RC.app", "cmux.app"]
            .map(|name| root.join(name).join("Contents/Library").join(HELPER_APP));
        for helper in candidates.into_iter().chain([root.join(HELPER_APP)]) {
            let binary = helper.join(HELPER_BINARY);
            if super::is_executable(&binary) && is_signed(&helper) {
                return Some(binary);
            }
        }
    }
    None
}

/// The signature verdict per helper, kept while its binary is unchanged
/// (same modified time): a lookup runs on every agent spawn, and codesign can
/// take up to its timeout, so it runs once per installed helper, not per chat.
#[cfg(target_os = "macos")]
fn verified_once(helper: &Path) -> bool {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    use std::time::SystemTime;

    static VERDICTS: OnceLock<Mutex<HashMap<PathBuf, (SystemTime, bool)>>> = OnceLock::new();
    let modified = std::fs::metadata(helper.join(HELPER_BINARY)).and_then(|m| m.modified()).ok();
    let Some(modified) = modified else { return false };
    let verdicts = VERDICTS.get_or_init(Default::default);
    if let Some(&(at, verdict)) = verdicts.lock().unwrap_or_else(|e| e.into_inner()).get(helper)
        && at == modified
    {
        return verdict;
    }
    let verdict = satisfies_requirement(helper);
    verdicts
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(helper.to_path_buf(), (modified, verdict));
    verdict
}

// This runs on the agent spawn path in the Rust daemon, never on the app's UI thread.
#[cfg(target_os = "macos")]
fn satisfies_requirement(helper: &Path) -> bool {
    use std::process::{Command, Stdio};
    use std::time::Duration;
    use wait_timeout::ChildExt;

    let Ok(mut child) = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--all-architectures", "--deep"])
        .arg(format!("-R={REQUIREMENT}"))
        .arg(helper)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    match child.wait_timeout(Duration::from_secs(3)) {
        Ok(Some(status)) => status.success(),
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            false
        }
    }
}

#[cfg(all(test, unix))]
#[path = "cua_helper_tests.rs"]
mod tests;
