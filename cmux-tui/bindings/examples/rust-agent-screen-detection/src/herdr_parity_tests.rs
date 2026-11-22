//! Behavior parity with herdr at the pinned upstream revision.
//!
//! herdr (https://github.com/ogulcancelik/herdr) is Apache-2.0; see
//! `manifests/LICENSE`. The process-identification cases below are adapted
//! from herdr's `src/detect/mod.rs` tests at commit
//! `2563803dca97c040beaf3dc3acdcb5a3221b4238` (Hermes installer capture from
//! e35f3937, Letta interactivity from fc1cb77f, Cline launchers from f3cbe03f,
//! Kimi and omp package launchers from 63ea2314 and cd8306d7), modified by
//! manaflow to drive the replaceable manifest catalog through `identify_job`.
//! `tests/fixtures/hermes-installer-process-info-4910.json` is herdr's
//! redacted reporter capture, copied unchanged. The screen fixtures are
//! manaflow-written from the comments in the vendored manifests.

use crate::manifest::{DetectionInput, ManifestSet, ScreenState};
use crate::process::{ForegroundJob, ForegroundProcess, identify_job};

fn screen(text: &str) -> DetectionInput<'_> {
    DetectionInput { screen: text, osc_title: "", osc_progress: "" }
}

fn detect(agent: &str, text: &str) -> (ScreenState, Option<String>) {
    let detection = ManifestSet::bundled().identify(agent).unwrap().detect(screen(text));
    (detection.state, detection.matched_rule)
}

fn process(pid: u32, name: &str, argv: &[&str]) -> ForegroundProcess {
    ForegroundProcess {
        pid,
        name: name.into(),
        argv0: argv.first().map(|value| (*value).into()),
        argv: argv.iter().map(|value| (*value).into()).collect(),
        cmdline: Some(argv.join(" ")),
    }
}

fn job(name: &str, argv: &[&str]) -> ForegroundJob {
    ForegroundJob { process_group_id: 123, processes: vec![process(123, name, argv)] }
}

fn identified(job: &ForegroundJob) -> Option<String> {
    identify_job(ManifestSet::bundled(), job).map(|(manifest, _)| manifest.id().to_string())
}

// ---- manifests (herdr 2563803d) -------------------------------------------

#[test]
fn agy_permission_question_and_trust_dialogs_are_blocked() {
    for (text, rule) in [
        (
            "Run this command?\n  ls -la\n↑/↓ Navigate · tab Amend · ctrl+g edit/expand command\nesc to cancel\n",
            "permission_prompt",
        ),
        (
            "Edit src/main.rs?\n↑/↓ Navigate · tab Amend · f full diff\nesc to cancel\n",
            "permission_prompt",
        ),
        (
            "Which test runner?\n❯ cargo test\n  nextest\n↑/↓ Navigate · enter Select · esc Skip\nesc to cancel\n",
            "question_prompt",
        ),
        (
            "Do you trust the contents of this project?\n❯ Yes, I trust this folder\n  No, exit\n↑/↓ Navigate · enter Confirm\n",
            "trust_prompt",
        ),
    ] {
        assert_eq!(detect("agy", text), (ScreenState::Blocked, Some(rule.into())), "{text}");
    }
}

#[test]
fn agy_mid_turn_thought_summary_and_esc_footer_are_working() {
    let summary = "⠹ The user wants the failing test fixed first\n╭──────────╮\n│ >        │\n╰──────────╯\n? for shortcuts\n";
    assert_eq!(detect("agy", summary), (ScreenState::Working, Some("spinner_working".into())));

    let footer = "Reading src/lib.rs\n╭──────────╮\n│ >        │\n────────────── esc to cancel\n";
    assert_eq!(
        detect("agy", footer),
        (ScreenState::Working, Some("esc_cancel_footer_working".into()))
    );
}

#[test]
fn agy_background_tasks_at_the_prompt_are_idle() {
    let text = "Done.\n╭──────────╮\n│ >        │\n╰──────────╯\n? for shortcuts · 2 tasks\n";
    assert_eq!(detect("agy", text).0, ScreenState::Idle);
}

#[test]
fn grok_background_commands_at_the_prompt_are_idle() {
    let text = "○ 2 commands still running · send a message to interrupt\n╭──────╮\n│ >    │\n╰──────╯\nTab:mode │ Ctrl+.:shortcuts\n";
    assert_eq!(detect("grok", text), (ScreenState::Idle, Some("prompt_hints_idle".into())));
}

#[test]
fn codex_folder_access_trust_dialog_is_blocked() {
    let text = "Folder access\n\n  Trust this folder?\n  Codex can read, edit, and run files here.\n\n  1. Trust and continue\n  2. Quit\n";
    assert_eq!(detect("codex", text), (ScreenState::Blocked, Some("trust_directory".into())));
}

#[test]
fn pi_spinner_working_line_is_working() {
    let text = "assistant output\n⠙ Working\n\n────────────────\n> \n";
    assert_eq!(detect("pi", text).0, ScreenState::Working);
}

// ---- process identification (herdr 2563803d src/detect/mod.rs) ------------

fn hermes_installer_capture() -> ForegroundJob {
    let capture: serde_json::Value = serde_json::from_str(include_str!(
        "../tests/fixtures/hermes-installer-process-info-4910.json"
    ))
    .unwrap();
    let info = &capture["result"]["process_info"];
    ForegroundJob {
        process_group_id: info["foreground_process_group_id"].as_u64().unwrap() as u32,
        processes: info["foreground_processes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|process| ForegroundProcess {
                pid: process["pid"].as_u64().unwrap() as u32,
                name: process["name"].as_str().unwrap().to_string(),
                argv0: Some(process["argv0"].as_str().unwrap().to_string()),
                argv: serde_json::from_value(process["argv"].clone()).unwrap(),
                cmdline: Some(process["cmdline"].as_str().unwrap().to_string()),
            })
            .collect(),
    }
}

#[test]
fn hermes_launched_through_its_python_installer_is_identified() {
    let mut job = hermes_installer_capture();
    assert_eq!(identified(&job).as_deref(), Some("hermes"));
    job.processes.retain(|process| process.pid == job.process_group_id);
    assert_eq!(identified(&job).as_deref(), Some("hermes"), "the group leader alone");

    let mut other_root = hermes_installer_capture();
    for process in &mut other_root.processes {
        for argument in &mut process.argv {
            *argument = argument.replace(
                "/Users/REDACTED/.hermes/hermes-agent",
                "/opt/another install/hermes-agent",
            );
        }
    }
    other_root.processes.retain(|process| process.pid == other_root.process_group_id);
    assert_eq!(identified(&other_root).as_deref(), Some("hermes"));
}

#[test]
fn hermes_installer_helper_modes_and_lookalike_source_are_not_hermes() {
    for mode in ["--run-module", "--print-runtime-command"] {
        let mut job = hermes_installer_capture();
        job.processes.retain(|process| process.pid == job.process_group_id);
        let argv = &mut job.processes[0].argv;
        argv.truncate(4);
        argv.extend([mode.into(), "tui_gateway.entry".into()]);
        assert_eq!(identified(&job), None, "{mode}");
    }

    let leader = {
        let mut job = hermes_installer_capture();
        job.processes.retain(|process| process.pid == job.process_group_id);
        job
    };
    let original = leader.processes[0].argv[3].clone();
    for code in [
        "print('hermes_cli.main')".to_string(),
        format!("'''{original}'''"),
        original.lines().map(|line| format!("# {line}\n")).collect(),
        original.replace("/Users/REDACTED", "/Users/has'quote"),
        original.replace("/Users/REDACTED", r"/Users/has\escape"),
        original.replacen("/Users/REDACTED", "/different/root", 1),
    ] {
        let mut job = leader.clone();
        job.processes[0].argv[3] = code;
        assert_eq!(identified(&job), None);
    }

    for prefix in
        [vec!["python3", "-m", "module"], vec!["python3", "script.py"], vec!["bash", "-I"]]
    {
        let mut argv = prefix.clone();
        argv.extend(["-c", original.as_str()]);
        assert_eq!(identified(&job(prefix[0], &argv)), None, "{prefix:?}");
    }
}

#[test]
fn interactive_letta_entrypoints_are_identified() {
    for argv in [
        vec!["letta", "--backend", "local"],
        vec![
            "node",
            "/home/user/project/node_modules/.bin/letta",
            "--conversation",
            "conversation-id",
        ],
        vec![
            "node.exe",
            r"C:\Users\user\AppData\Roaming\npm\node_modules\@letta-ai\letta-code\letta.js",
            "--agent",
            "agent-id",
        ],
    ] {
        assert_eq!(identified(&job("MainThread", &argv)).as_deref(), Some("letta"), "{argv:?}");
    }
}

#[test]
fn noninteractive_letta_processes_are_not_agent_sessions() {
    for args in [
        vec!["--prompt", "hello"],
        vec!["-p", "hello"],
        vec!["--output-format", "json"],
        vec!["--input-format=stream-json"],
        vec!["--ephemeral"],
        vec!["--max-turns=1"],
        vec!["server"],
        vec!["--backend", "local", "server"],
        vec!["fix this bug"],
        vec!["agents", "list"],
        vec!["version"],
    ] {
        let mut argv = vec!["node", "/home/user/project/node_modules/.bin/letta"];
        argv.extend(args.iter().copied());
        assert_eq!(identified(&job("MainThread", &argv)), None, "{argv:?}");
        let mut direct = vec!["letta"];
        direct.extend(args.iter().copied());
        assert_eq!(identified(&job("letta", &direct)), None, "{direct:?}");
    }
    assert_eq!(identified(&job("node", &["node", "/tmp/server.js", "letta"])), None);
    assert_eq!(
        identified(&job("node", &["node", "/home/user/src/letta-code/letta/build.js"])),
        None
    );
}

#[test]
fn cline_native_and_node_launchers_are_identified() {
    for (name, argv) in [
        (".cline", vec!["/home/user/.npm/lib/node_modules/cline/bin/.cline", "--tui"]),
        ("cline", vec!["/usr/local/lib/node_modules/@cline/cli-darwin-arm64/bin/cline", "--tui"]),
        ("MainThread", vec!["node", "/home/user/.fnm/bin/cline", "--tui"]),
        ("node", vec!["node", "/usr/local/lib/node_modules/cline/bin/cline"]),
    ] {
        assert_eq!(identified(&job(name, &argv)).as_deref(), Some("cline"), "{argv:?}");
    }
}

#[test]
fn unrelated_cline_mentions_are_not_identified() {
    for argv in [
        vec!["node"],
        vec!["node", "/path/to/other.js", "cline"],
        vec!["node", "-e", "cline"],
        vec!["node", "/path/to/cline-helper"],
        vec!["/path/to/.cline-helper"],
        vec!["/path/to/other", "/path/to/cline"],
    ] {
        assert_eq!(identified(&job("MainThread", &argv)), None, "{argv:?}");
    }
}

#[test]
fn kimi_and_omp_package_launchers_are_identified() {
    let kimi = job(
        "node.exe",
        &[
            r"C:\Program Files\nodejs\node.exe",
            r"C:\repro-3317-kimi-prefix\node_modules\@moonshot-ai\kimi-code\dist\main.mjs",
        ],
    );
    assert_eq!(identified(&kimi).as_deref(), Some("kimi"));
    assert_eq!(
        identified(&job(
            "node",
            &["node", "/usr/local/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"]
        ))
        .as_deref(),
        Some("kimi")
    );

    // omp has no bundled screen manifest; a userland manifest can claim it.
    let omp = ManifestSet::from_sources(&[(
        "omp",
        "id = \"omp\"\nversion = \"1\"\n\n[[rules]]\nid = \"idle\"\nstate = \"idle\"\ncontains = [\"ready\"]\n",
    )])
    .unwrap();
    let packaged = job(
        "bun.exe",
        &[
            "bun.exe",
            r"C:\Users\herdr\AppData\Roaming\npm\node_modules\@oh-my-pi\pi-coding-agent\dist\cli.js",
        ],
    );
    assert_eq!(identify_job(&omp, &packaged).map(|(manifest, _)| manifest.id()), Some("omp"));
    let setup = job(
        "bun.exe",
        &[
            "bun.exe",
            r"C:\Users\herdr\AppData\Roaming\npm\node_modules\@oh-my-pi\pi-coding-agent\dist\setup.js",
        ],
    );
    assert!(identify_job(&omp, &setup).is_none());
}
