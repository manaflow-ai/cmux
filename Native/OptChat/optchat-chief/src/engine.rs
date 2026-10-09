//! The Chief's engine settings (Lawrence, 2026-10-05: "visibility into the
//! model / harness, and swap it between turns"): the turn harness, model and
//! reasoning effort, and the compactor's harness and model, in
//! `$MUX_HOME/optchat/engine.json` (0600). The host reads the turn fields at
//! EACH turn start, so a change applies from the next turn without a
//! restart; a running turn finishes on its engine. The compactor fields
//! apply at the next host start (its sessions' presets and slot directories
//! are made for one harness family at start).
//!
//! `optchat-chief engine show|set` (also `chief engine ...` in a turn) reads
//! and writes the file; the app can show and write the same file.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// What `engine.json` holds; a missing field is the host's default (its env).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct EngineChoice {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compactor_harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compactor_model: Option<String>,
}

/// One turn's engine, resolved against the host's defaults.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnEngine {
    pub harness: String,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl TurnEngine {
    /// `harness=claude model=claude-opus-5-5 effort=high` (default when unset).
    pub fn describe(&self) -> String {
        format!(
            "harness={} model={} effort={}",
            self.harness,
            self.model.as_deref().unwrap_or("default"),
            self.effort.as_deref().unwrap_or("default")
        )
    }
}

/// `$MUX_HOME/optchat/engine.json`.
pub fn path(home: &Path) -> PathBuf {
    crate::paths::Paths::new(home).root.join("engine.json")
}

/// The file's choice; missing or unreadable is the empty choice (defaults).
pub fn load(path: &Path) -> EngineChoice {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Writes the choice through a temporary file (0600) and a rename.
pub fn save(path: &Path, choice: &EngineChoice) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    let mut bytes = serde_json::to_vec_pretty(choice).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    file.write_all(&bytes)?;
    file.sync_all()?;
    std::fs::rename(&tmp, path)
}

/// The compactor's harness setting at host start: `env`
/// (`OPTCHAT_COMPACTOR_HARNESS`), else engine.json's `compactor_harness`;
/// None leaves the host's default.
pub fn compactor_harness_setting(env: Option<String>, choice: &EngineChoice) -> Option<String> {
    env.or_else(|| choice.compactor_harness.clone())
}

/// The turn engine of `choice` over the defaults.
pub fn resolve(
    choice: &EngineChoice,
    harness: &str,
    model: Option<&str>,
    effort: Option<&str>,
) -> TurnEngine {
    TurnEngine {
        harness: choice.harness.clone().unwrap_or_else(|| harness.to_owned()),
        model: choice.model.clone().or_else(|| model.map(str::to_owned)),
        effort: choice.effort.clone().or_else(|| effort.map(str::to_owned)),
    }
}

/// `engine set` flags over the current choice: `--harness`, `--model`,
/// `--effort`, `--compactor-harness`, `--compactor-model`; the value
/// `default` clears a field.
pub fn apply_flags(
    mut choice: EngineChoice,
    flags: &crate::cli::Flags,
) -> Result<EngineChoice, String> {
    let mut changed = false;
    for (key, field) in [
        ("harness", &mut choice.harness),
        ("model", &mut choice.model),
        ("effort", &mut choice.effort),
        ("compactor-harness", &mut choice.compactor_harness),
        ("compactor-model", &mut choice.compactor_model),
    ] {
        if let Some(value) = flags.value(key) {
            changed = true;
            *field = match value.trim() {
                "" | "default" => None,
                v => Some(v.to_owned()),
            };
        }
    }
    if !changed {
        return Err(USAGE.into());
    }
    Ok(choice)
}

pub const USAGE: &str = "chief engine show
chief engine set [--harness H] [--model M] [--effort E] [--compactor-harness H] [--compactor-model M]   (value `default` clears; turns apply it from the next turn, the compactor at the next host start)";

/// `engine show|set`; Ok carries what to print.
pub fn run(flags: &crate::cli::Flags) -> Result<String, String> {
    let home = flags
        .value("mux-home")
        .map(PathBuf::from)
        .unwrap_or_else(crate::paths::mux_home);
    let file = path(&home);
    match flags.words.get(1).map(String::as_str) {
        Some("set") => {
            let choice = apply_flags(load(&file), flags)?;
            save(&file, &choice).map_err(|e| format!("{}: {e}", file.display()))?;
            Ok(format!(
                "engine set: {}\nTurns use it from the next turn; the compactor fields apply at the next host start.\n",
                serde_json::to_string(&choice).expect("json")
            ))
        }
        Some("show") | None => {
            let choice = load(&file);
            let mut out = format!(
                "engine ({}): {}\n",
                file.display(),
                serde_json::to_string(&choice).expect("json")
            );
            // The last turn the trace saw: which engine answered, and its stats.
            let since = chrono::Local::now().timestamp_millis().max(0) as u64;
            let events = crate::report::read(
                &crate::trace::dir(&home),
                since.saturating_sub(7 * 86_400_000),
            )
            .unwrap_or_default();
            if let Some(end) = events.iter().rev().find(|e| e["ev"] == "turn.end") {
                out.push_str(&format!(
                    "last turn: {} model {} effort {}: {} in {} ms, {} tool call(s) ({} failed), cache hit {}, cost {}\n",
                    end["harness"].as_str().unwrap_or("?"),
                    end["model"].as_str().unwrap_or("default"),
                    end["effort"].as_str().unwrap_or("default"),
                    end["status"].as_str().unwrap_or("?"),
                    end["ms"],
                    end["tools"],
                    end["tool_errors"],
                    crate::report::hit_rate(&end["usage"])
                        .map_or("-".to_owned(), |h| format!("{:.0}%", h * 100.0)),
                    end["cost_usd"]
                        .as_f64()
                        .map_or("-".to_owned(), |c| format!("${c:.4}"))
                ));
            }
            Ok(out)
        }
        _ => Err(USAGE.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_show_and_resolve() {
        let dir = tempfile::tempdir().unwrap();
        let file = path(dir.path());
        assert_eq!(load(&file), EngineChoice::default());
        let args: Vec<String> = [
            "engine",
            "set",
            "--harness",
            "codex",
            "--model",
            "gpt-6-sol",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let choice = apply_flags(load(&file), &crate::cli::Flags::parse(&args)).unwrap();
        save(&file, &choice).unwrap();
        let back = load(&file);
        assert_eq!(back.harness.as_deref(), Some("codex"));
        let engine = resolve(&back, "claude-sr", None, Some("high"));
        assert_eq!(
            engine.describe(),
            "harness=codex model=gpt-6-sol effort=high"
        );
        let clear: Vec<String> = ["engine", "set", "--harness", "default"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let back = apply_flags(back, &crate::cli::Flags::parse(&clear)).unwrap();
        assert_eq!(resolve(&back, "claude-sr", None, None).harness, "claude-sr");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
