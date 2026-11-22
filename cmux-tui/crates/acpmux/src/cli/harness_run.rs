//! `cmux harness run ID [--cwd DIR] [--model M]` (BRING-YOUR-OWN-HARNESS,
//! terminal fallback): run a `protocol = "terminal"` harness, a CLI or TUI
//! without ACP, in the current terminal with its profile env.
//!
//! Keychain and login-variable references are resolved in this process and
//! go only to the harness's environment, never into a command line. `cmux
//! harness run ID --tab` (the cmux binary) opens a new tab whose process is
//! this command, so the secrets are resolved inside that tab too.
//! An ACP or Claude Code profile is refused: it runs in an agent chat.
//! A folder profile runs only when enabled for a folder that holds `--cwd`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};

use crate::config::folder_profiles;
use crate::config::{Config, HarnessKind, HarnessProfile};

/// What `run` starts: the command line, the env added to this process's,
/// and the working folder.
#[derive(Debug, PartialEq, Eq)]
pub struct RunPlan {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: PathBuf,
}

/// Lookups for env references (tests pass fakes).
pub struct Lookups<'a> {
    pub env: &'a dyn Fn(&str) -> Option<String>,
    pub keychain: &'a dyn Fn(&str, Option<&str>) -> Result<String, String>,
}

/// The plan for harness `id` in folder `cwd`.
pub fn run_plan(
    cfg: &Config,
    id: &str,
    cwd: &Path,
    model: Option<&str>,
    lookups: &Lookups<'_>,
) -> Result<RunPlan> {
    let profile: HarnessProfile = match cfg.profile(id) {
        Some(p) => p.clone(),
        None => match folder_profiles::resolve_for_session(cfg, id, cwd, false) {
            Some(found) => found.map_err(|e| anyhow!(e.message))?.0,
            None => bail!("unknown harness {id:?}; see `cmux harness list`"),
        },
    };
    if profile.kind != HarnessKind::Terminal {
        bail!(
            "harness {id} speaks {}, so it runs in an agent chat (`cmux acp new -m {id}`); `harness run` is for protocol = \"terminal\" harnesses",
            if profile.kind == HarnessKind::Acp { "ACP" } else { "the Claude Code protocol" }
        );
    }
    let model = model.map(str::to_owned).or_else(|| cfg.defaults_for(id).model).or(profile.model);
    let takes_model =
        profile.argv.iter().chain(profile.env.values()).any(|v| v.contains("${model}"));
    if takes_model && model.is_none() {
        bail!("harness {id} takes ${{model}}; pass --model");
    }
    let model = model.unwrap_or_default();
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let mut env = profile.env.clone();
    profiles_resolve(&mut env, lookups)?;
    let env = env
        .into_iter()
        .map(|(k, v)| (k, crate::hub::expand_env_value(&v, cwd, &home, &model)))
        .collect();
    let argv =
        profile.argv.iter().map(|a| crate::hub::expand_env_value(a, cwd, &home, &model)).collect();
    Ok(RunPlan { argv, env, cwd: cwd.to_owned() })
}

fn profiles_resolve(env: &mut BTreeMap<String, String>, lookups: &Lookups<'_>) -> Result<()> {
    crate::config::profiles::resolve_env_refs(env, lookups.env, lookups.keychain)
        .map_err(|e| anyhow!(e))
}

/// `cmux harness run`: replace this process with the harness.
pub fn run_cmd(id: &str, cwd: Option<PathBuf>, model: Option<String>) -> Result<()> {
    use std::os::unix::process::CommandExt;
    let cfg = Config::load()?;
    let cwd = match cwd {
        Some(dir) => dir,
        None => std::env::current_dir()?,
    };
    let cwd = std::fs::canonicalize(&cwd).map_err(|e| anyhow!("{}: {e}", cwd.display()))?;
    let env_lookup = |var: &str| std::env::var(var).ok();
    let lookups = Lookups { env: &env_lookup, keychain: &crate::config::profiles::keychain_lookup };
    let plan = run_plan(&cfg, id, &cwd, model.as_deref(), &lookups)?;
    let mut cmd = std::process::Command::new(&plan.argv[0]);
    cmd.args(&plan.argv[1..]).envs(&plan.env).current_dir(&plan.cwd);
    crate::config::scrub_nested_claude_env(&mut cmd);
    // exec only returns on failure.
    let error = cmd.exec();
    Err(anyhow!("cannot start {}: {error}", plan.argv[0]))
}

#[cfg(test)]
#[path = "harness_run_tests.rs"]
mod tests;
