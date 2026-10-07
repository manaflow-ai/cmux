//! `cmux harness list --folder DIR`, `enable ID --folder DIR`, `disable ID
//! --folder DIR`: folder profiles (BRING-YOUR-OWN-HARNESS H4,
//! `config/folder_profiles.rs`).
//!
//! `enable` shows the exact command line, each env key with its source, and
//! the file's hash, then asks y/N on a terminal. Without a terminal it needs
//! `--yes`. It refuses a folder without a `trusted` answer, and it records
//! only the bytes it showed.

use std::io::{BufRead, IsTerminal, Write};
use std::path::Path;

use anyhow::{Result, anyhow, bail};
use serde_json::json;

use crate::config::Config;
use crate::config::folder_profiles::{self, FolderGate, FolderProfile, FolderState};
use crate::config::profiles::Severity;

fn gate(cfg: &Config) -> Result<&FolderGate> {
    cfg.folder_gate.as_ref().ok_or_else(|| anyhow!("no home folder: folder profiles are off"))
}

pub fn list(folder: &Path, json_out: bool) -> Result<()> {
    let cfg = Config::load()?;
    let rows = folder_profiles::scan(&cfg, gate(&cfg)?, folder).map_err(|e| anyhow!(e))?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&json!({"folderProfiles": rows}))?);
        return Ok(());
    }
    if rows.is_empty() {
        println!("no folder profiles in {}", folder_profiles::profile_dir(folder).display());
    }
    for r in &rows {
        println!("{:<16} {:<13} trust:{:<10} {}", r.id, state_name(r.state), r.trust, r.path);
        for d in &r.diagnostics {
            let level = if d.severity == Severity::Error { "error" } else { "warning" };
            println!("  {level}: {}", d.message);
            if let Some(fix) = &d.fix {
                println!("    fix: {fix}");
            }
        }
        if let Some(next) = next_step(r) {
            println!("  next: {next}");
        }
    }
    Ok(())
}

fn state_name(state: FolderState) -> &'static str {
    match state {
        FolderState::NeedsTrust => "needs-trust",
        FolderState::NeedsEnable => "needs-enable",
        FolderState::Enabled => "enabled",
        FolderState::Error => "error",
    }
}

/// What the user does next for a folder profile.
pub fn next_step(r: &FolderProfile) -> Option<String> {
    match r.state {
        FolderState::NeedsTrust => Some(format!(
            "answer the Trust question for {} (open a cmux chat in it), then `cmux harness enable {} --folder {}`",
            r.folder, r.id, r.folder
        )),
        FolderState::NeedsEnable => {
            Some(format!("cmux harness enable {} --folder {}", r.id, r.folder))
        }
        FolderState::Enabled | FolderState::Error => None,
    }
}

pub fn enable_cmd(id: &str, folder: &Path, yes: bool, json_out: bool) -> Result<()> {
    let cfg = Config::load()?;
    let gate = gate(&cfg)?;
    let fp = folder_profiles::load_one(&cfg, gate, folder, id).ok_or_else(|| {
        anyhow!("{} has no {id}.toml", folder_profiles::profile_dir(folder).display())
    })?;
    let program = fp.profile.as_ref().and_then(|p| super::harness::find_program(&p.argv[0]));
    let text = folder_profiles::confirmation_text(&fp, program.as_deref());
    let sha = match (fp.state, fp.sha256.clone()) {
        (FolderState::Enabled, _) => {
            println!("{id} is already enabled for {}", fp.folder);
            return Ok(());
        }
        (FolderState::NeedsEnable, Some(sha)) => sha,
        _ => bail!(folder_profiles::refusal(&fp).unwrap_or_else(|| format!("cannot enable {id}"))),
    };
    eprint!("{text}");
    if !yes {
        let stdin = std::io::stdin();
        if !stdin.is_terminal() {
            bail!("no terminal to confirm on; read the command above, then pass --yes");
        }
        eprint!("Enable harness {id}? [y/N] ");
        std::io::stderr().flush()?;
        let mut answer = String::new();
        stdin.lock().read_line(&mut answer)?;
        if !matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
            bail!("not enabled");
        }
    }
    let enabled = folder_profiles::enable(&cfg, gate, folder, id, &sha).map_err(|e| anyhow!(e))?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&enabled)?);
    } else {
        println!("enabled {id} for chats inside {}", enabled.folder);
    }
    Ok(())
}

pub fn disable_cmd(id: &str, folder: &Path) -> Result<()> {
    let cfg = Config::load()?;
    if folder_profiles::disable(gate(&cfg)?, folder, id).map_err(|e| anyhow!(e))? {
        println!("disabled {id} for {}", folder.display());
    } else {
        println!("{id} was not enabled for {}", folder.display());
    }
    Ok(())
}
