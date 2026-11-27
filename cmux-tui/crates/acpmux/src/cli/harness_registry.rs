//! `cmux harness registry` and `cmux harness add ID --registry` (cx-1785):
//! the ACP Registry's agents (`registry.rs`), how each can start here, and
//! a profile file that starts one at the registry's pinned version.

use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use serde_json::json;

use crate::config::profiles::{self, ProfileSources};
use crate::config::{ProfileSource, home, which};
use crate::registry::{self, Launch, Registry};

/// The cached registry, fetched (and saved) first when `refresh` is set or
/// no copy is saved yet.
pub(crate) async fn registry(refresh: bool) -> Result<Registry> {
    let home = home();
    if !refresh && let Some(cached) = registry::load_cached(&home) {
        return Ok(cached);
    }
    registry::refresh(&home).await.map_err(|e| anyhow!("ACP Registry: {e}"))?;
    registry::load_cached(&home)
        .ok_or_else(|| anyhow!("ACP Registry: the saved copy does not parse"))
}

pub async fn list_cmd(refresh: bool, json_out: bool) -> Result<()> {
    let reg = registry(refresh).await?;
    let platform = registry::platform();
    let rows: Vec<_> = reg
        .agents
        .iter()
        .map(|agent| {
            let launch = agent.launch(platform, &which);
            let detail = match &launch {
                Launch::Installed { argv, .. } => argv.first().cloned().unwrap_or_default(),
                Launch::Npx { .. } => {
                    agent.npx.as_ref().map(|p| p.package.clone()).unwrap_or_default()
                }
                Launch::Uvx { .. } => {
                    agent.uvx.as_ref().map(|p| p.package.clone()).unwrap_or_default()
                }
                Launch::Download { archive, .. } => archive.clone(),
                Launch::Unavailable => String::new(),
            };
            (agent, registry::harness_id(&agent.id), launch.method(), detail)
        })
        .collect();
    if json_out {
        let list: Vec<_> = rows
            .iter()
            .map(|(agent, harness, method, detail)| {
                json!({"id": agent.id, "harness": harness, "name": agent.name,
                       "version": agent.version, "license": agent.license,
                       "website": agent.website, "launch": method, "detail": detail})
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&json!({"agents": list}))?);
        return Ok(());
    }
    for (agent, _, method, detail) in &rows {
        println!("{:<22} {:<12} {:<11} {}", agent.id, agent.version, method, detail);
    }
    println!(
        "\n`installed` agents are harnesses already. Add another with `cmux harness add <id> --registry` \
         (npx/uvx run the registry's pinned package; `download` agents: install them from their page first)."
    );
    Ok(())
}

/// Writes `~/.config/cmux-next/harnesses/<harness id>.toml` for registry agent
/// `id`, started the way [`registry::Agent::launch`] picks.
pub fn add(
    reg: &Registry,
    id: &str,
    force: bool,
    sources: &ProfileSources,
    which: &dyn Fn(&str) -> Option<String>,
) -> Result<(String, PathBuf)> {
    let agent = reg
        .agent(id)
        .ok_or_else(|| anyhow!("no ACP Registry agent {id:?}; see `cmux harness registry`"))?;
    let Some(harness) = registry::harness_id(&agent.id) else {
        bail!(
            "registry id {id:?} does not make a harness id (1-40 lowercase letters, digits or '-')"
        );
    };
    if matches!(harness.as_str(), "claude" | "claude-sr") {
        bail!("{harness} is acpmux's own Claude Code route; it cannot come from the registry");
    }
    let launch = agent.launch(registry::platform(), which);
    let Some(text) = registry::profile_toml(agent, &launch) else {
        return Err(match launch {
            Launch::Download { archive, .. } => anyhow!(
                "{} ships only a binary archive; install it ({archive}), then run this again",
                agent.name
            ),
            _ => anyhow!("{} cannot start here: install npx (Node.js) or uvx (uv)", agent.name),
        });
    };
    let dir = sources
        .user_dir
        .clone()
        .ok_or_else(|| anyhow!("no harness folder: set HOME or XDG_CONFIG_HOME"))?;
    let path = dir.join(format!("{harness}.toml"));
    if path.exists() && !force {
        bail!("{} exists; pass --force to replace it", path.display());
    }
    // The file must parse before it is written.
    if let Err(errors) =
        profiles::parse_profile_toml(&text, &path, Some(&harness), ProfileSource::UserFile)
    {
        bail!("the registry profile does not load: {errors:?}");
    }
    #[cfg(unix)]
    {
        crate::home_fs::create_dir_all(&dir, 0o700)?;
    }
    #[cfg(windows)]
    crate::owner_only::create_dir_all(&dir)?;
    crate::config::write_atomic(&path, text.as_bytes())?;
    Ok((harness, path))
}

pub async fn add_cmd(id: &str, force: bool, json_out: bool) -> Result<()> {
    let reg = registry(false).await?;
    let reg = if reg.agent(id).is_none() { registry(true).await? } else { reg };
    let (harness, path) = add(&reg, id, force, &ProfileSources::current(), &which)?;
    let reloaded = super::harness::reload_daemon().await;
    if json_out {
        println!("{}", json!({"id": harness, "path": path, "daemonReloaded": reloaded}));
    } else {
        println!("wrote {}", path.display());
        println!(
            "next: `cmux harness doctor {harness}` (it signs in on first use if the agent asks)"
        );
    }
    Ok(())
}

#[cfg(test)]
#[path = "harness_registry_tests.rs"]
mod tests;
