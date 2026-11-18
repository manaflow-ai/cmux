//! `cmux harness list --folder DIR`, `enable ID --folder DIR`, `disable ID
//! --folder DIR`: folder profiles (BRING-YOUR-OWN-HARNESS H4,
//! `config/folder_profiles.rs`).
//!
//! `enable` shows the exact command line, each env key with its source, and
//! the file's hash, then asks y/N on a terminal. Without a terminal it needs
//! `--yes`. It refuses a folder without a `trusted` answer, and it records
//! only the bytes it showed.

use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow, bail};
use serde_json::json;

use crate::config::folder_profiles::{self, FolderGate, FolderProfile, FolderState};
use crate::config::profiles::Severity;
use crate::config::{Config, HarnessProfile};

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

/// What `enable` shows before it asks: the confirmation text and the hash
/// it confirms, or that these bytes are already enabled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Confirmation {
    AlreadyEnabled { folder: String },
    Ask { text: String, sha256: String },
}

/// The confirmation `enable` shows for folder profile `id` of `folder`: the
/// text of the shared prompt (`folder_profiles::prepare_enable`), the same
/// text the app's Enable sheet gets from `_acpmux/harness_enable`.
pub fn confirmation(cfg: &Config, folder: &Path, id: &str) -> Result<Confirmation> {
    let shown = folder_profiles::prepare_enable(cfg, gate(cfg)?, folder, id)
        .map_err(|e| anyhow!(e.message().to_owned()))?;
    let fp = shown.profile;
    match (fp.state, fp.sha256) {
        (FolderState::Enabled, _) => Ok(Confirmation::AlreadyEnabled { folder: fp.folder }),
        (FolderState::NeedsEnable, Some(sha256)) => {
            let text = shown.prompt["text"].as_str().unwrap_or_default().to_owned();
            Ok(Confirmation::Ask { text, sha256 })
        }
        _ => bail!("cannot enable {id}"),
    }
}

pub fn enable_cmd(id: &str, folder: &Path, yes: bool, json_out: bool) -> Result<()> {
    let cfg = Config::load()?;
    let gate = gate(&cfg)?;
    let (text, sha) = match confirmation(&cfg, folder, id)? {
        Confirmation::AlreadyEnabled { folder } => {
            println!("{id} is already enabled for {folder}");
            return Ok(());
        }
        Confirmation::Ask { text, sha256 } => (text, sha256),
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

/// The one daemon request `disable ID --folder DIR` sends: `_acpmux/harness_disable
/// {folder, id}`, the folder made absolute against the current folder (the daemon takes only
/// an absolute one). The command palette's Disable Folder Harness row sends the same.
pub fn disable_request(id: &str, folder: &Path) -> Result<(&'static str, serde_json::Value)> {
    let folder = std::path::absolute(folder)
        .map_err(|e| anyhow!("{}: {e}", folder.display()))?
        .to_string_lossy()
        .into_owned();
    Ok((crate::rpc::method::MUX_HARNESS_DISABLE, json!({"folder": folder, "id": id})))
}

/// The one typed daemon request a `harness …` argv (the words after `cmux` or `acpmux`)
/// sends, for the verbs that send exactly one: `harness disable ID --folder DIR`. None for
/// any other argv; `Some(Err)` for one clap or the folder refuses. cmux-tui's
/// `catalog_request_matches_cli` compares it with the palette row.
pub fn sent_request(args: &[String]) -> Option<Result<(&'static str, serde_json::Value)>> {
    use crate::cli::command::{Cli, Command, HarnessCmd};
    use clap::Parser as _;
    let argv = std::iter::once("acpmux").chain(args.iter().map(String::as_str));
    let cli = match Cli::try_parse_from(argv) {
        Ok(cli) => cli,
        Err(error) => return Some(Err(anyhow!(error.to_string()))),
    };
    match cli.command? {
        Command::Harness(HarnessCmd::Disable { id, folder }) => Some(disable_request(&id, &folder)),
        _ => None,
    }
}

/// `disable ID --folder DIR`: sends [`disable_request`] to the running daemon, so the CLI
/// and the app withdraw the same way. With no daemon running it writes the same enable
/// record itself (`folder_profiles::disable`, what the daemon runs), as the folder
/// commands work without a daemon.
pub async fn disable_cmd(id: &str, folder: &Path) -> Result<()> {
    let (method, params) = disable_request(id, folder)?;
    let disabled = match crate::daemon::connect(false).await {
        Ok(client) => {
            let reply = client.request(method, params).await?;
            reply.get("disabled").and_then(serde_json::Value::as_bool).unwrap_or(false)
        }
        Err(_) => {
            let cfg = Config::load()?;
            folder_profiles::disable(gate(&cfg)?, folder, id).map_err(|e| anyhow!(e))?
        }
    };
    if disabled {
        println!("disabled {id} for {}", folder.display());
    } else {
        println!("{id} was not enabled for {}", folder.display());
    }
    Ok(())
}

/// An enabled folder profile that `cmux harness doctor` checks.
pub struct DoctorTarget {
    pub profile: HarnessProfile,
    /// The folder that holds `.cmux/harnesses`; doctor starts the harness in it.
    pub folder: PathBuf,
    pub path: String,
}

/// `cmux harness doctor ID` for an id the catalog does not have: folder
/// profile `id` of `start` or its nearest parent that has the file. None: no
/// folder has it. Err((detail, fix)): it may not run now; `fix` is the next
/// step (`next_step`), or the file's own fix for an invalid file.
pub fn doctor_target(
    cfg: &Config,
    id: &str,
    start: &Path,
) -> Option<Result<DoctorTarget, (String, Option<String>)>> {
    let gate = cfg.folder_gate.as_ref()?;
    let fp = folder_profiles::find_nearest(cfg, gate, id, start)?;
    Some(match (fp.state, fp.profile.clone()) {
        (FolderState::Enabled, Some(profile)) => {
            Ok(DoctorTarget { profile, folder: PathBuf::from(&fp.folder), path: fp.path })
        }
        (FolderState::NeedsEnable, _) => Err((
            format!(
                "{id} is a folder profile in {} that is not enabled (or changed since it was enabled)",
                fp.folder
            ),
            next_step(&fp),
        )),
        (FolderState::NeedsTrust, _) => {
            Err((folder_profiles::refusal(&fp).unwrap_or_default(), next_step(&fp)))
        }
        _ => {
            let fix = fp.diagnostics.iter().find(|d| d.severity == Severity::Error);
            let fix = fix.and_then(|d| d.fix.clone());
            let detail = folder_profiles::refusal(&fp)
                .unwrap_or_else(|| format!("{}: the profile cannot be used", fp.path));
            Err((detail, fix))
        }
    })
}
