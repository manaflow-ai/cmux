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
    /// `fast` (the priority tier) or none (`default`): turns, then the
    /// compactor (its slots, at the next host start).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compactor_speed: Option<String>,
    /// The reaction classifier's harness (reaction_wake.rs); None: the
    /// user's `chief.reactionClassifier.harness`, else the host's Claude route.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub classifier_harness: Option<String>,
    /// The reaction classifier's model; None: the user's, else Claude Haiku.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub classifier_model: Option<String>,
    /// The reaction classifier's prompt; None: the user's, else the built-in one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub classifier_prompt: Option<String>,
    /// Whether a user's reaction on a Chief message may wake this Chief;
    /// None: the user's `chief.reactionsCanWake`, else on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reactions_can_wake: Option<bool>,
    /// Whether `spawn` may name its subagents' harness or model: `auto` or
    /// `off`; None: cmux.json `chief.autoRouteSubagents`, else off (Leo,
    /// 2026-11-01: "optional ofc we don't wanna change defaults or whatnot
    /// yet").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_routing: Option<String>,
    /// The harness a spawn that names none runs its subagents on, routing
    /// on or off; None: the turn's (or OPTCHAT_SUBAGENT_HARNESS, which wins).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent_harness: Option<String>,
}

/// The values `subagent_routing` takes.
pub const SUBAGENT_ROUTINGS: &[&str] = &["auto", "off"];

/// The Chief kinds `engine set --preset` writes in one step (Leo, 2026-10-23:
/// "we can have vanilla all opus 5.5 med chief, we can have forced hybrid
/// chief, and we can have pure codex chief").
pub const PRESETS: &[&str] = &["opus", "hybrid", "codex"];

/// The choice a preset writes over `choice`: turns, compactor and subagents.
/// The reaction classifier and the prompt fields are kept.
/// - `opus`: every turn on Claude Opus 5.5 at medium; the compactor and the
///   subagents follow the Claude route.
/// - `hybrid`: Opus 5.5 medium turns, every subagent forced onto codex
///   (routing off, so a spawn cannot name another harness).
/// - `codex`: turns, compactor and subagents on codex at their default
///   model, fast.
pub fn apply_preset(mut choice: EngineChoice, preset: &str) -> Result<EngineChoice, String> {
    let some = |v: &str| Some(v.to_owned());
    let (harness, model, effort, speed, compactor, subagents) = match preset.trim() {
        "opus" => (
            some("claude"),
            some("claude-opus-5-5"),
            some("medium"),
            None,
            None,
            None,
        ),
        "hybrid" => (
            some("claude"),
            some("claude-opus-5-5"),
            some("medium"),
            None,
            None,
            some("codex"),
        ),
        "codex" => (
            some("codex"),
            None,
            None,
            some("fast"),
            some("codex"),
            some("codex"),
        ),
        other => {
            return Err(format!(
                "--preset is one of {}, not {other:?}",
                PRESETS.join(", ")
            ));
        }
    };
    choice.harness = harness;
    choice.model = model;
    choice.effort = effort;
    // The compactor runs at the turns' speed (fast only on codex).
    choice.compactor_speed = speed.clone();
    choice.speed = speed;
    choice.compactor_harness = compactor;
    choice.compactor_model = None;
    choice.subagent_harness = subagents;
    choice.subagent_routing = some("off");
    Ok(choice)
}

/// The speeds a Chief engine takes: `default` (the harness's) and `fast`
/// (codex's priority tier, "2x speed, increased usage").
pub const SPEEDS: &[&str] = &["default", "fast"];

/// Whether `speed` can run on a `family` harness: Err with the reason when
/// it cannot (Claude Code's adapter has no fast mode).
pub fn check_speed(speed: &str, family: crate::acpmux::Family) -> Result<(), String> {
    use crate::acpmux::Family;
    match (speed.trim(), family) {
        ("" | "default", _) | ("fast", Family::Codex) => Ok(()),
        ("fast", Family::Claude) => Err(
            "speed fast is not available on a Claude harness: Claude Code's acpmux adapter has no fast mode"
                .to_owned(),
        ),
        ("fast", Family::Other) => {
            Err("speed fast is available only on a codex harness".to_owned())
        }
        (other, _) => Err(format!("speed {other} is not one of {}", SPEEDS.join(", "))),
    }
}

/// Whether `speed` names the fast tier.
pub fn is_fast(speed: Option<&str>) -> bool {
    speed.map(str::trim) == Some("fast")
}

/// One turn's engine, resolved against the host's defaults.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnEngine {
    pub harness: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// `fast` (engine.json `speed`, else `OPTCHAT_CHIEF_SPEED`); None: default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
}

impl TurnEngine {
    /// `harness=claude model=claude-opus-5-5 effort=high` (default when unset).
    pub fn describe(&self) -> String {
        let mut text = format!(
            "harness={} model={} effort={}",
            self.harness,
            self.model.as_deref().unwrap_or("default"),
            self.effort.as_deref().unwrap_or("default")
        );
        if let Some(speed) = &self.speed {
            text.push_str(&format!(" speed={speed}"));
        }
        text
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

/// One role's harness as the host resolved it at its start: the acpmux
/// profile, its kind, the executable it runs and that executable's
/// `--version`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedHarness {
    pub harness: String,
    pub kind: String,
    pub argv0: String,
    #[serde(default)]
    pub version: String,
}

/// What the running host resolved for its turns, compactor and subagents
/// (`$MUX_HOME/optchat/engine-resolved.json`, written at each host start),
/// so `engine show` names the CLI each one runs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedEngine {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<ResolvedHarness>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compactor: Option<ResolvedHarness>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subagent: Option<ResolvedHarness>,
}

/// `$MUX_HOME/optchat/engine-resolved.json`.
pub fn resolved_path(home: &Path) -> PathBuf {
    crate::paths::Paths::new(home)
        .root
        .join("engine-resolved.json")
}

/// Writes what the host resolved (through a temporary file and a rename).
pub fn save_resolved(home: &Path, resolved: &ResolvedEngine) -> std::io::Result<()> {
    let path = resolved_path(home);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut bytes = serde_json::to_vec_pretty(resolved).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, path)
}

/// The last host start's resolution; None when no host wrote one.
pub fn load_resolved(home: &Path) -> Option<ResolvedEngine> {
    std::fs::read(resolved_path(home))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

/// The first line of `program --version`, or "" when it does not answer
/// within 5 s (a wrapper that hangs never holds the host's start).
pub fn binary_version(program: &str) -> String {
    let Ok(mut child) = std::process::Command::new(program)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        return String::new();
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() < deadline => {
                // Bounded wait for a short-lived child; no async runtime here.
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return String::new();
            }
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = std::io::Read::read_to_string(&mut stdout, &mut out);
    }
    out.lines().next().unwrap_or("").trim().to_owned()
}

/// The compactor's harness setting at host start: `env`
/// (`OPTCHAT_COMPACTOR_HARNESS`), else engine.json's `compactor_harness`.
/// None leaves the compactor on Claude Haiku (Lawrence 2026-10-09) over the
/// turns' engine harness when it is a Claude one, else the host's Claude
/// route (`host::compactor_harness_for`).
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
        speed: choice
            .speed
            .clone()
            .or_else(|| crate::cli::env("OPTCHAT_CHIEF_SPEED"))
            .filter(|s| is_fast(Some(s))),
    }
}

/// `engine set` flags over the current choice: `--harness`, `--model`,
/// `--effort`, `--compactor-harness`, `--compactor-model`, `--speed`,
/// `--compactor-speed`, and the reaction classifier's
/// `--reactions-can-wake`, `--classifier-harness`, `--classifier-model`,
/// `--classifier-prompt`, and the subagents' `--subagent-routing auto|off`
/// and `--subagent-harness`; the value `default` clears a field. `--preset`
/// applies first, so the other flags adjust it.
pub fn apply_flags(
    mut choice: EngineChoice,
    flags: &crate::cli::Flags,
) -> Result<EngineChoice, String> {
    let mut changed = false;
    if let Some(preset) = flags.value("preset") {
        changed = true;
        choice = apply_preset(choice, preset)?;
    }
    for (key, field) in [
        ("harness", &mut choice.harness),
        ("model", &mut choice.model),
        ("effort", &mut choice.effort),
        ("compactor-harness", &mut choice.compactor_harness),
        ("compactor-model", &mut choice.compactor_model),
        ("speed", &mut choice.speed),
        ("compactor-speed", &mut choice.compactor_speed),
        ("classifier-harness", &mut choice.classifier_harness),
        ("classifier-model", &mut choice.classifier_model),
        ("classifier-prompt", &mut choice.classifier_prompt),
        ("subagent-harness", &mut choice.subagent_harness),
    ] {
        if let Some(value) = flags.value(key) {
            changed = true;
            *field = match value.trim() {
                "" | "default" => None,
                v => Some(v.to_owned()),
            };
        }
    }
    if let Some(value) = flags.value("reactions-can-wake") {
        changed = true;
        choice.reactions_can_wake = match value.trim() {
            "" | "default" => None,
            "true" | "on" => Some(true),
            "false" | "off" => Some(false),
            other => {
                return Err(format!(
                    "--reactions-can-wake is true, false or default, not {other:?}"
                ));
            }
        };
    }
    if let Some(value) = flags.value("subagent-routing") {
        changed = true;
        choice.subagent_routing = match value.trim() {
            "" | "default" => None,
            v if SUBAGENT_ROUTINGS.contains(&v) => Some(v.to_owned()),
            other => {
                return Err(format!(
                    "--subagent-routing is auto, off or default, not {other:?}"
                ));
            }
        };
    }
    if !changed {
        return Err(USAGE.into());
    }
    Ok(choice)
}

pub const USAGE: &str = "chief engine show
chief engine set --preset opus|hybrid|codex   (opus: Opus 5.5 medium everywhere; hybrid: Opus 5.5 medium turns, every subagent on codex; codex: codex everywhere, fast; other flags adjust it)
chief engine set [--harness H] [--model M] [--effort E] [--compactor-harness H] [--compactor-model M] [--speed default|fast] [--compactor-speed default|fast] [--reactions-can-wake true|false] [--classifier-harness H] [--classifier-model M] [--classifier-prompt TEXT] [--subagent-routing auto|off] [--subagent-harness H]   (value `default` clears; turns apply it from the next turn, the compactor at the next host start, the reaction classifier at the next reaction, the subagent fields at the next spawn; routing is off unless set to auto)";

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
            // The CLI each role runs, as the host resolved it at its start.
            match load_resolved(&home) {
                Some(r) => {
                    for (role, h) in [
                        ("turn", &r.turn),
                        ("compactor", &r.compactor),
                        ("subagent", &r.subagent),
                    ] {
                        if let Some(h) = h {
                            let version = if h.version.is_empty() {
                                "version unknown"
                            } else {
                                &h.version
                            };
                            out.push_str(&format!(
                                "{role}: {} ({}, {}, {version})\n",
                                h.harness, h.kind, h.argv0
                            ));
                        }
                    }
                }
                None => out.push_str(
                    "resolved: unknown (the host has not started since it began recording this)\n",
                ),
            }
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
