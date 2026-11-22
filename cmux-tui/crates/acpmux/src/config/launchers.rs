//! Owns launcher probing and subrouter fallback profile verification.

use super::*;

/// Drop discovered launcher profiles whose binary cannot actually run the
/// harness: an older subrouter without `claude proxy`, one whose proxy
/// setup fails before Claude starts, or a configured CodeRouter route
/// (`claude-cr`) the installed CLI does not have. Runs once at daemon start, so a
/// `claude` session never fails over into a launcher that dies at once.
pub fn verify_launchers(cfg: &mut Config) {
    let servers =
        dirs::home_dir().map(|home| home.join(".subrouter/codex/servers.json")).unwrap_or_default();
    let env_route =
        std::env::var("SUBROUTER_URL").ok().or_else(|| crate::login_env::var("SUBROUTER_URL"));
    let route = subrouter_route(env_route.as_deref(), &servers);
    verify_launchers_with(cfg, route);
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
    let candidates: Vec<(String, Vec<String>)> = cfg
        .harnesses
        .iter()
        .filter(|(n, p)| {
            is_subrouter_proxy(&p.argv)
                || (n.as_str() == super::CODEROUTER_CLAUDE_PROFILE
                    && p.kind == HarnessKind::ClaudeStdio)
        })
        .map(|(n, p)| (n.clone(), p.argv.clone()))
        .collect();
    for (name, argv) in candidates {
        if let Err(reason) = launcher_ok(&argv) {
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
fn is_subrouter_proxy(argv: &[String]) -> bool {
    argv.get(1).map(String::as_str) == Some("claude")
        && argv.get(2).map(String::as_str) == Some("proxy")
}

pub(crate) fn launcher_ok(argv: &[String]) -> std::result::Result<(), String> {
    let shown = argv
        .iter()
        .enumerate()
        .map(|(i, w)| if i == 0 { w.rsplit('/').next().unwrap_or(w) } else { w.as_str() })
        .collect::<Vec<_>>()
        .join(" ");
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
    // Warnings (a peer that could not be reached) are not failures.
    let first = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with("warning:"))
        .unwrap_or("")
        .to_owned();
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
    let path = crate::login_env::path()?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(bin);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}
