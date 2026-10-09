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
async fn registry(refresh: bool) -> Result<Registry> {
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

/// Writes `~/.config/cmux/harnesses/<harness id>.toml` for registry agent
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
    let harness = registry::harness_id(&agent.id);
    if !profiles::valid_id(&harness) {
        bail!(
            "registry id {id:?} does not make a harness id (1-40 lowercase letters, digits or '-')"
        );
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
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    }
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
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../tests/fixtures/acp-registry.json");

    #[test]
    fn add_writes_a_loadable_profile_once() {
        let reg = registry::parse(FIXTURE.as_bytes()).unwrap();
        let dir = std::env::temp_dir().join(format!("acpmux-reg-add-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sources =
            ProfileSources { user_dir: Some(dir.join("harnesses")), ..ProfileSources::none() };
        let npx = |bin: &str| (bin == "npx").then(|| "/u/bin/npx".to_owned());
        let (id, path) = add(&reg, "github-copilot-cli", false, &sources, &npx).unwrap();
        assert_eq!(id, "github-copilot-cli");
        let loaded = profiles::load(&sources);
        assert!(loaded.diagnostics.is_empty(), "{:?}", loaded.diagnostics);
        assert_eq!(
            loaded.profiles["github-copilot-cli"].0.argv,
            vec![
                "/u/bin/npx".to_owned(),
                "-y".into(),
                "@github/copilot@1.0.93".into(),
                "--acp".into()
            ]
        );
        assert!(add(&reg, "github-copilot-cli", false, &sources, &npx).is_err());
        assert!(add(&reg, "github-copilot-cli", true, &sources, &npx).is_ok());
        // Known agents keep acpmux's ids.
        assert_eq!(add(&reg, "grok-build", false, &sources, &npx).unwrap().0, "grok");
        // An archive-only agent that is not installed is refused with its page.
        let err = add(&reg, "goose", false, &sources, &npx).unwrap_err().to_string();
        assert!(err.contains("binary archive") || err.contains("cannot start"), "{err}");
        assert!(add(&reg, "nope", false, &sources, &npx).is_err());
        let _ = std::fs::remove_dir_all(&dir);
        let _ = path;
    }
}
