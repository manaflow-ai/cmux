//! Owns launcher probing and subrouter fallback profile verification.

use super::*;

/// Drop discovered launcher profiles whose binary cannot actually run the
/// harness: an older subrouter without `claude proxy`, one whose proxy
/// setup fails before Claude starts. Runs once at daemon start, so a
/// `claude` session never fails over into a launcher that dies at once.
pub fn verify_launchers(cfg: &mut Config) {
    // A capture fixture's harnesses name no installed program, and nothing
    // of this host (`~/.subrouter`) is read (`harness_fixture.rs`).
    if crate::harness_fixture::active().is_some() {
        return;
    }
    let servers =
        dirs::home_dir().map(|home| home.join(".subrouter/codex/servers.json")).unwrap_or_default();
    let env_route =
        std::env::var("SUBROUTER_URL").ok().or_else(|| crate::login_env::var("SUBROUTER_URL"));
    let route = subrouter_route(env_route.as_deref(), &servers);
    let cache = home().join(CHECKS_FILE);
    verify_launchers_cached(cfg, route, &cache, &launcher_ok);
}

/// Successful checks of current launcher binaries, replaced once per verification pass.
const CHECKS_FILE: &str = "launcher-checks.json";

/// Probe changed launchers in parallel, then publish one combined cache. Each pass keeps only
/// successful current keys: updates and removed profiles cannot grow the file indefinitely.
/// Reading and rewriting the file inside each parallel probe lost other probes' successes.
fn verify_launchers_cached(
    cfg: &mut Config,
    route: Option<String>,
    cache: &std::path::Path,
    probe: &(dyn Fn(&[String]) -> std::result::Result<(), String> + Sync),
) {
    let previous: std::collections::BTreeSet<String> = std::fs::read(cache)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let passed = std::sync::Mutex::new(std::collections::BTreeSet::new());
    verify_launchers_checked(cfg, route, &|argv| {
        let key = launcher_key(argv);
        if !key.as_ref().is_some_and(|key| previous.contains(key)) {
            probe(argv)?;
        }
        if let Some(key) = key {
            passed.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(key);
        }
        Ok(())
    });
    let passed = passed.into_inner().unwrap_or_else(std::sync::PoisonError::into_inner);
    // A warm start with the same candidates needs no durable write.
    if passed != previous
        && let Ok(bytes) = serde_json::to_vec(&passed)
        && let Err(e) = write_atomic(cache, &bytes)
    {
        tracing::debug!("launcher checks not saved: {e:#}");
    }
}

/// What a launcher check is of: its argv and its binary's size and modification time. None when
/// the binary is not found: it is checked every time.
fn launcher_key(argv: &[String]) -> Option<String> {
    let bin = argv.first()?;
    let path = if bin.contains('/') { bin.clone() } else { which(bin)? };
    let meta = std::fs::metadata(&path).ok()?;
    let modified = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
    Some(format!("{}\0{path}\0{}\0{modified}", argv.join("\u{1f}"), meta.len()))
}

/// The subrouter server Claude traffic goes to when `sr` has no `claude proxy`:
/// `SUBROUTER_URL`, else the default server in `sr`'s own list
/// (`~/.subrouter/codex/servers.json`, read only). Only an http(s) URL counts.
pub fn subrouter_route(env_url: Option<&str>, servers_json: &std::path::Path) -> Option<String> {
    let http = |url: &str| {
        let url = url.trim().trim_end_matches('/');
        (url.starts_with("http://") || url.starts_with("https://")).then(|| url.to_owned())
    };
    if let Some(url) = env_url.and_then(http) {
        return Some(url);
    }
    let value: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(servers_json).ok()?).ok()?;
    let default = value.get("default")?.as_str()?;
    value
        .get("servers")?
        .as_array()?
        .iter()
        .find(|server| server.get("name").and_then(|n| n.as_str()) == Some(default))?
        .get("url")?
        .as_str()
        .and_then(http)
}

/// `verify_launchers` with the subrouter route given: a proxy launcher that
/// fails becomes the `claude` profile routed through that server when there
/// is one and it is acpmux's own adapter (`claude-stdio`), else it is
/// marked unavailable.
pub fn verify_launchers_with(cfg: &mut Config, route: Option<String>) {
    verify_launchers_checked(cfg, route, &launcher_ok);
}

/// [`verify_launchers_with`], each launcher checked by `check`, all at once: one slow launcher
/// holds no other.
fn verify_launchers_checked(
    cfg: &mut Config,
    route: Option<String>,
    check: &(dyn Fn(&[String]) -> std::result::Result<(), String> + Sync),
) {
    let candidates: Vec<(String, Vec<String>)> = cfg
        .harnesses
        .iter()
        .filter(|(_, p)| is_subrouter_proxy(&p.argv))
        .map(|(n, p)| (n.clone(), p.argv.clone()))
        .collect();
    let checked: Vec<_> = std::thread::scope(|scope| {
        let runs: Vec<_> =
            candidates.iter().map(|(_, argv)| scope.spawn(move || check(argv))).collect();
        runs.into_iter()
            .map(|run| run.join().unwrap_or_else(|_| Err("the launcher check panicked".into())))
            .collect()
    });
    for ((name, argv), result) in candidates.into_iter().zip(checked) {
        if let Err(reason) = result {
            // Only acpmux's own adapter takes over: claude-sr never becomes
            // an ACP adapter (`claude` imported from ~/.acpx, say).
            if is_subrouter_proxy(&argv)
                && let Some(url) = &route
                && let Some(claude) = cfg
                    .harnesses
                    .get("claude")
                    .filter(|c| c.kind == HarnessKind::ClaudeStdio)
                    .cloned()
            {
                tracing::info!(agent = %name, %url, "{reason}; routing Claude through the subrouter server");
                let mut env = claude.env.clone();
                env.insert("ANTHROPIC_BASE_URL".into(), url.clone());
                // The server picks the pooled account and ignores the client token.
                env.insert("ANTHROPIC_AUTH_TOKEN".into(), "subrouter".into());
                env.insert("ANTHROPIC_CUSTOM_HEADERS".into(), "X-Subrouter-Agent: claude".into());
                let previous = cfg.harnesses.get(&name).cloned();
                cfg.harnesses.insert(
                    name.clone(),
                    HarnessProfile {
                        kind: claude.kind,
                        argv: claude.argv.clone(),
                        env,
                        description: Some(format!("Claude through the subrouter server {url}")),
                        fallback: None,
                        family: previous
                            .as_ref()
                            .and_then(|p| p.family.clone())
                            .or(Some("claude".into())),
                        models: previous.as_ref().map(|p| p.models.clone()).unwrap_or_default(),
                        model: previous.as_ref().and_then(|p| p.model.clone()),
                        effort: previous.as_ref().and_then(|p| p.effort.clone()),
                        policy: previous.as_ref().and_then(|p| p.policy),
                    },
                );
                continue;
            }
            tracing::warn!(agent = %name, "launcher unavailable: {reason}");
            cfg.unavailable.insert(name.clone(), reason);
            for p in cfg.harnesses.values_mut() {
                if p.fallback.as_deref() == Some(name.as_str()) {
                    p.fallback = None;
                }
            }
        }
    }
}

/// `sr claude proxy` (the subrouter account pool).
pub fn is_subrouter_proxy(argv: &[String]) -> bool {
    argv.get(1).map(String::as_str) == Some("claude")
        && argv.get(2).map(String::as_str) == Some("proxy")
}

pub(crate) fn launcher_ok(argv: &[String]) -> std::result::Result<(), String> {
    let shown = argv[0].rsplit('/').next().unwrap_or(&argv[0]);
    let mut cmd = std::process::Command::new(&argv[0]);
    crate::login_env::apply_std(&mut cmd);
    cmd.args(&argv[1..])
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    scrub_nested_claude_env(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("{}: {e}", argv[0]))?;
    // Woken by the child's exit (SIGCHLD), not a polling tick.
    use wait_timeout::ChildExt;
    match child.wait_timeout(std::time::Duration::from_secs(20)) {
        Ok(Some(_)) => {}
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("`{shown} --version` did not finish in 20s"));
        }
        Err(e) => return Err(e.to_string()),
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    // Each pipe is its own stream: a control one leaves open does not hide the other's lines.
    let mut cleaned = [&out.stdout, &out.stderr]
        .into_iter()
        .flat_map(|pipe| crate::stderr::clean_stderr_lines(&String::from_utf8_lossy(pipe)));
    // Warnings (a peer that could not be reached) are not failures.
    let first = cleaned.find(|l| !l.is_empty() && !l.starts_with("warning:")).unwrap_or_default();
    if !out.status.success()
        || first.starts_with("subrouter:")
        || text.to_lowercase().contains("unknown command")
    {
        return Err(format!(
            "`{shown} --version` failed: {}",
            if first.is_empty() { out.status.to_string() } else { first }
        ));
    }
    Ok(())
}

pub(crate) fn which(bin: &str) -> Option<String> {
    which_in(&crate::login_env::path().unwrap_or_default(), bin)
        .or_else(|| native_install(bin))
        .or_else(|| image_install(bin))
}

/// Where a Cloud machine's image puts its harnesses (`claude`, `codex`, ...): only a login shell
/// lists it on PATH, and the daemon's unit PATH does not. When the 3 s login-shell read timed out
/// on a just-booted machine, the daemon found no `claude`, and the start was refused as
/// `agent_session.harness_missing`: "Claude (`claude`) isn't installed on that machine"
/// (production probe 2026-11-26T15:20:44Z, vm_a6cbc8f2cc82f6433bcc). Checking the image's own
/// directory makes discovery stop depending on that read.
const IMAGE_BIN_DIR: &str = "/opt/cmux/current/bin";

/// `bin` in the Cloud image's harness directory ([`IMAGE_BIN_DIR`]), if it can run there.
fn image_install(bin: &str) -> Option<String> {
    image_install_in(std::path::Path::new(IMAGE_BIN_DIR), bin)
}

/// [`image_install`] under `dir`.
fn image_install_in(dir: &std::path::Path, bin: &str) -> Option<String> {
    if bin.is_empty() || bin.contains('/') {
        return None;
    }
    let candidate = dir.join(bin);
    crate::harness_install::is_executable(&candidate)
        .then(|| candidate.to_string_lossy().into_owned())
}

/// A program the daemon runs from config or a fleet tool by bare name (`sendRelay.argv`'s
/// `lane-gh`, `peerWake`, `cmux-ci`), as a path it can spawn. A systemd user daemon starts with
/// the system PATH, which lists no `~/.local/bin`, where lane VMs install those tools: every MCP
/// `send` on a lane VM failed with "cannot run the send relay \"lane-gh\": No such file or
/// directory" (gcp-agent-lane-13, 2026-11-21) while the same `lane-gh` ran from a shell. Looks in
/// the login PATH (or this process's), then `~/.local/bin` and `~/.cmux/bin`. A name with a `/`,
/// or one found nowhere, comes back as given, so the spawn's own error still names it.
pub(crate) fn user_program(program: &str) -> std::path::PathBuf {
    if program.contains('/') {
        return program.into();
    }
    let path = crate::login_env::path().unwrap_or_default();
    user_program_in(&path, dirs::home_dir().as_deref(), program)
}

/// [`user_program`] with its PATH and home given.
fn user_program_in(
    path: &std::ffi::OsStr,
    home: Option<&std::path::Path>,
    program: &str,
) -> std::path::PathBuf {
    if let Some(found) = which_in(path, program) {
        return found.into();
    }
    for dir in [".local/bin", ".cmux/bin"] {
        if let Some(candidate) = home.map(|h| h.join(dir).join(program))
            && crate::harness_install::is_executable(&candidate)
        {
            return candidate;
        }
    }
    program.into()
}

/// `bin` in the directories of `path`, in order.
pub(crate) fn which_in(path: &std::ffi::OsStr, bin: &str) -> Option<String> {
    for dir in std::env::split_paths(path) {
        let candidate = dir.join(bin);
        // As a shell's lookup: a file it could not run does not hide a runnable one later on PATH.
        if crate::harness_install::is_executable(&candidate) {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

/// Claude Code's and Codex's own installers put `claude` and `codex` in `~/.local/bin`, which a login
/// PATH may not list (the installers only ask the person to add it), and a daemon read that PATH when
/// it started: so one installed there (`acpmux harness install`, the Harnesses page's Install on a Mac
/// with no npm) is found on the next look. Without it a fresh Mac's Codex install ended in "cmux can't
/// run it yet" (first-run findings row 3).
fn native_install(bin: &str) -> Option<String> {
    native_install_in(&dirs::home_dir()?, bin)
}

/// [`native_install`] under `home`.
fn native_install_in(home: &std::path::Path, bin: &str) -> Option<String> {
    if !matches!(bin, "claude" | "codex") {
        return None;
    }
    let candidate = home.join(".local/bin").join(bin);
    // A stale or non-executable file there is no installed CLI (as `harness install` checks).
    crate::harness_install::is_executable(&candidate)
        .then(|| candidate.to_string_lossy().into_owned())
}

#[cfg(all(test, unix))]
mod tests {
    use super::which_in;
    use std::os::unix::fs::PermissionsExt as _;

    /// A `claude` the shell could not run (no execute bit) earlier on PATH does not hide the one it
    /// would run.
    #[test]
    fn which_skips_a_file_it_could_not_run() {
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        std::fs::write(first.path().join("claude"), "").unwrap();
        let runnable = second.path().join("claude");
        std::fs::write(&runnable, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&runnable, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::join_paths([first.path(), second.path()]).unwrap();
        assert_eq!(which_in(&path, "claude"), Some(runnable.to_string_lossy().into_owned()));
        assert_eq!(which_in(&path, "codex"), None);
    }

    /// Codex's own installer (`chatgpt.com/codex/install.sh`, what the Harnesses page's Install runs
    /// on a Mac with no npm) puts `codex` in `~/.local/bin`, as Claude Code's does, and a fresh Mac's
    /// login PATH does not list it: after Install the row said "Finished, but cmux can't run it yet"
    /// (first-run findings row 3). Both are found there; a file that cannot run is no install.
    #[test]
    fn codex_and_claude_from_their_own_installers_are_found_in_local_bin() {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join(".local/bin");
        std::fs::create_dir_all(&bin).unwrap();
        for name in ["codex", "claude"] {
            let file = bin.join(name);
            std::fs::write(&file, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
            assert_eq!(
                super::native_install_in(home.path(), name),
                Some(file.to_string_lossy().into_owned()),
                "{name}"
            );
        }
        std::fs::write(bin.join("opencode"), "").unwrap();
        assert_eq!(super::native_install_in(home.path(), "opencode"), None);
        let empty = tempfile::tempdir().unwrap();
        assert_eq!(super::native_install_in(empty.path(), "codex"), None);
    }

    /// A Cloud image keeps `claude` in `/opt/cmux/current/bin`, which only a login shell lists on
    /// PATH: with the login-shell read timed out, a just-booted machine refused the start as "Claude
    /// (`claude`) isn't installed on that machine" (production probe 2026-11-26T15:20:44Z). The
    /// image directory finds it; a file that cannot run, or a name with a slash, does not.
    #[test]
    fn a_harness_in_the_cloud_image_dir_is_found_without_the_login_path() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("claude");
        std::fs::write(&file, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            super::image_install_in(dir.path(), "claude"),
            Some(file.to_string_lossy().into_owned())
        );
        std::fs::write(dir.path().join("codex"), "").unwrap();
        assert_eq!(super::image_install_in(dir.path(), "codex"), None);
        assert_eq!(super::image_install_in(dir.path(), "../claude"), None);
        assert_eq!(super::image_install_in(dir.path(), "opencode"), None);
    }
}

#[cfg(test)]
#[path = "launchers_cache_tests.rs"]
mod cache_tests;
