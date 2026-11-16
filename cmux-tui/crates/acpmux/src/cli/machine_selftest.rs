//! The unattended remote spin-up acceptance runner.
//!
//! Fleet providers differ (a Linux VM is joined over ssh while the GUI half is
//! driven on an owned Mac), so the provider-specific actions live in a small
//! checked-in or generated scenario file. This module owns the contract that
//! every provider shares: bounded ordered steps, action accounting, timing,
//! cleanup/error reporting, and one machine-readable result.

use anyhow::{Result, anyhow};
use serde::Serialize;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

const DEFAULT_SCENARIO_ENV: &str = "CMUX_MACHINE_SELFTEST_SCENARIO";
const REQUIRED_STEPS: [&str; 6] =
    ["door-a-cli", "door-a-gui", "first-chat", "drop-10s", "drop-60s", "remove"];

#[derive(Debug, Clone)]
struct ScenarioStep {
    name: String,
    actions: u32,
    command: String,
}

#[derive(Debug, Serialize)]
struct StepResult {
    step: String,
    actions: u32,
    seconds: f64,
    error: Option<String>,
}

#[derive(Debug, Serialize)]
struct Report {
    steps: Vec<StepResult>,
    total_actions: u32,
    total_seconds: f64,
    max_actions: u32,
    max_seconds: u64,
    passed: bool,
}

fn parse_scenario(text: &str) -> Result<Vec<ScenarioStep>> {
    let mut steps = Vec::new();
    for (line_no, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut fields = line.splitn(3, '\t');
        let name = fields.next().unwrap_or_default().trim();
        let actions = fields.next().unwrap_or_default().trim();
        let command = fields.next().unwrap_or_default().trim();
        if name.is_empty() || command.is_empty() {
            return Err(anyhow!(
                "scenario line {} must be step<TAB>actions<TAB>command",
                line_no + 1
            ));
        }
        let actions: u32 = actions
            .parse()
            .map_err(|_| anyhow!("scenario line {} has invalid action count", line_no + 1))?;
        if command.to_ascii_lowercase().contains("cmux16") {
            return Err(anyhow!(
                "scenario line {} targets cmux16; lease an owned fleet Mac instead",
                line_no + 1
            ));
        }
        let command_lower = command.to_ascii_lowercase();
        if name == "door-a-cli"
            && (!command_lower.contains("ssh") || !command_lower.contains("join"))
        {
            return Err(anyhow!(
                "scenario line {} door-a-cli must run the join over ssh",
                line_no + 1
            ));
        }
        if name == "door-a-gui" && !command_lower.contains("cmux action run") {
            return Err(anyhow!(
                "scenario line {} door-a-gui must drive the app through `cmux action run`",
                line_no + 1
            ));
        }
        let required_marker = match name {
            "first-chat" => {
                Some(("chat", "first-chat must start a chat and wait for its first reply"))
            }
            "drop-10s" => Some(("10", "drop-10s must exercise a ten-second link drop")),
            "drop-60s" => Some(("60", "drop-60s must exercise a sixty-second link drop")),
            "remove" => Some(("remove", "remove must remove both machines and verify cleanup")),
            _ => None,
        };
        if let Some((marker, message)) = required_marker {
            if !command_lower.contains(marker) {
                return Err(anyhow!("scenario line {} {message}", line_no + 1));
            }
        }
        steps.push(ScenarioStep { name: name.to_owned(), actions, command: command.to_owned() });
    }
    if steps.is_empty() {
        return Err(anyhow!("scenario has no steps"));
    }
    for required in REQUIRED_STEPS {
        if !steps.iter().any(|step| step.name == required) {
            return Err(anyhow!(
                "scenario is missing required {required} step (the remote spin-up flow is not skippable)"
            ));
        }
    }
    Ok(steps)
}

fn error_text(status: Option<i32>, stderr: &[u8]) -> String {
    let detail = String::from_utf8_lossy(stderr).trim().replace('\n', " ");
    let detail = if detail.chars().count() > 500 {
        format!("{}…", detail.chars().take(500).collect::<String>())
    } else {
        detail
    };
    match (status, detail.is_empty()) {
        (Some(code), true) => format!("command exited {code}"),
        (Some(code), false) => format!("command exited {code}: {detail}"),
        (None, true) => "command terminated without an exit status".to_owned(),
        (None, false) => format!("command terminated: {detail}"),
    }
}

/// Run the scenario and print the one JSON table required by the remote
/// spin-up check. A failed step or exceeded budget is returned as an error so
/// the CLI exits non-zero after the report has been emitted.
pub fn run(
    scenario: Option<PathBuf>,
    max_actions: u32,
    max_seconds: u64,
    _json_out: bool,
) -> Result<()> {
    let path = scenario
        .or_else(|| env::var_os(DEFAULT_SCENARIO_ENV).map(PathBuf::from))
        .ok_or_else(|| anyhow!("machine selftest needs --scenario or ${DEFAULT_SCENARIO_ENV}"))?;
    let steps = parse_scenario(
        &fs::read_to_string(&path).map_err(|e| anyhow!("read scenario {}: {e}", path.display()))?,
    )?;
    let started = Instant::now();
    let mut total_actions = 0_u32;
    let mut results = Vec::with_capacity(steps.len());
    for step in steps {
        total_actions = total_actions.saturating_add(step.actions);
        let step_started = Instant::now();
        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg(&step.command)
            .env("CMUX_SELFTEST_STEP", &step.name)
            .output()
            .map_err(|e| anyhow!("run step {}: {e}", step.name));
        let error = match output {
            Ok(output) if output.status.success() => None,
            Ok(output) => Some(error_text(output.status.code(), &output.stderr)),
            Err(error) => Some(error.to_string()),
        };
        results.push(StepResult {
            step: step.name,
            actions: step.actions,
            seconds: (step_started.elapsed().as_secs_f64() * 1000.0).round() / 1000.0,
            error,
        });
    }
    let total_seconds = (started.elapsed().as_secs_f64() * 1000.0).round() / 1000.0;
    let failed_step =
        results.iter().find(|step| step.error.is_some()).map(|step| step.step.clone());
    let budget_error = (total_actions > max_actions)
        .then(|| format!("actions {total_actions} exceed budget {max_actions}"));
    let time_error = (total_seconds > max_seconds as f64)
        .then(|| format!("seconds {total_seconds:.3} exceed budget {max_seconds}"));
    let passed = failed_step.is_none() && budget_error.is_none() && time_error.is_none();
    let report =
        Report { steps: results, total_actions, total_seconds, max_actions, max_seconds, passed };
    println!("{}", serde_json::to_string(&report)?);
    if passed {
        Ok(())
    } else {
        let mut reasons = Vec::new();
        if let Some(step) = failed_step {
            reasons.push(format!("step {step} failed"));
        }
        if let Some(error) = budget_error {
            reasons.push(error);
        }
        if let Some(error) = time_error {
            reasons.push(error);
        }
        Err(anyhow!("machine selftest failed: {}", reasons.join("; ")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_comments_and_tabs() {
        let steps = parse_scenario(
            "# comment\ndoor-a-cli\t1\tssh vm join\ndoor-a-gui\t1\tcmux action run gui\nfirst-chat\t1\tfleet-driver chat-first-reply\ndrop-10s\t0\tfleet-driver drop-link 10\ndrop-60s\t0\tfleet-driver drop-link 60\nremove\t1\tfleet-driver remove\n",
        )
        .unwrap();
        assert_eq!(steps.len(), 6);
        assert_eq!(steps[2].actions, 1);
    }

    #[test]
    fn allows_wait_steps_without_an_action() {
        assert_eq!(
            parse_scenario(
                "door-a-cli\t1\tssh vm join\ndoor-a-gui\t1\tcmux action run gui\nfirst-chat\t1\tfleet-driver chat-first-reply\ndrop-10s\t0\tfleet-driver drop-link 10\ndrop-60s\t0\tfleet-driver drop-link 60\nremove\t1\tfleet-driver remove\n"
            )
            .unwrap()[3]
                .actions,
            0
        );
    }

    #[test]
    fn requires_both_door_a_paths() {
        assert!(parse_scenario("door-a-cli\t1\tssh vm true\n").is_err());
        assert!(
            parse_scenario("door-a-cli\t1\tssh vm join\ndoor-a-gui\t1\tcmux action run gui\n")
                .is_err()
        );
    }

    #[test]
    fn rejects_cmux16() {
        assert!(parse_scenario("door-a-cli\t1\tssh vm join\ndoor-a-gui\t1\tcmux16\n").is_err());
    }

    #[test]
    fn requires_real_chat_and_link_drop_drivers() {
        let scenario = "door-a-cli\t1\tssh vm join\n\
            door-a-gui\t1\tcmux action run gui\n\
            first-chat\t1\tfleet-driver chat-first-reply\n\
            drop-10s\t0\tdrop\n\
            drop-60s\t0\tdrop 60\n\
            remove\t1\tfleet-driver remove\n";
        assert!(parse_scenario(scenario).is_err());
    }
}
