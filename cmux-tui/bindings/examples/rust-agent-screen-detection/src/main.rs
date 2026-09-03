use std::env;
use std::path::Path;
use std::process::ExitCode;

const MAX_EXPLAIN_SCREEN_BYTES: usize = 8 * 1024 * 1024;

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let command = args.next();
    match command.as_deref() {
        Some("--help") | Some("-h") => {
            print_help();
            return ExitCode::SUCCESS;
        }
        Some("list") => return run_list(),
        Some("status") => return run_status(),
        Some("explain") => return run_explain(args.collect()),
        Some("update") => return run_update(args.collect()),
        Some(other) => {
            eprintln!("cmux-agent-screen-detection: unknown command {other:?}");
            print_help();
            return ExitCode::from(2);
        }
        None => {}
    }

    let socket = match env::var("CMUX_TUI_SOCKET") {
        Ok(value) if !value.is_empty() => value,
        _ => {
            eprintln!("cmux-agent-screen-detection: CMUX_TUI_SOCKET is required");
            return ExitCode::FAILURE;
        }
    };
    let session = env::var("CMUX_TUI_SESSION_ID").unwrap_or_else(|_| "main".into());
    let plugin_id = match required_plugin_id(env::var("CMUX_PLUGIN_ID").ok()) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("cmux-agent-screen-detection: {error}");
            return ExitCode::FAILURE;
        }
    };
    match cmux_agent_screen_detection::scanner::run(&socket, &session, &plugin_id) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-agent-screen-detection: {error}");
            ExitCode::FAILURE
        }
    }
}

fn required_plugin_id(value: Option<String>) -> Result<String, String> {
    let Some(value) = value else {
        return Err("CMUX_PLUGIN_ID is required".into());
    };
    if value.trim().is_empty() {
        return Err("CMUX_PLUGIN_ID must not be blank".into());
    }
    cmux_agent_screen_detection::scanner::validate_plugin_id(&value)
        .map_err(|error| format!("invalid CMUX_PLUGIN_ID: {error}"))?;
    Ok(value)
}

fn run_list() -> ExitCode {
    match cmux_agent_screen_detection::manifest::ManifestSet::from_environment() {
        Ok(set) => {
            let manifests = set
                .manifests()
                .map(|manifest| {
                    serde_json::json!({
                        "id": manifest.id(),
                        "version": manifest.version().map(ToString::to_string),
                        "source": manifest.source().label(),
                    })
                })
                .collect::<Vec<_>>();
            print_json(&serde_json::json!({
                "engine_version": cmux_agent_screen_detection::manifest::SCREEN_DETECT_ENGINE_VERSION,
                "manifests": manifests,
            }))
        }
        Err(error) => print_error(error),
    }
}

fn run_status() -> ExitCode {
    let cache_dir = cmux_agent_screen_detection::manifest_update::environment_cache_dir();
    print_json(&cmux_agent_screen_detection::manifest_update::status_json(&cache_dir))
}

fn run_explain(arguments: Vec<String>) -> ExitCode {
    let live = arguments.iter().any(|argument| argument == "--live");
    let mut process = None;
    let mut screen_path = None;
    let mut live_target = None;
    let mut title = String::new();
    let mut progress = String::new();
    let mut json_output = true;
    let mut index = 0;
    while index < arguments.len() {
        let value = &arguments[index];
        let next = |index: &mut usize, name: &str| -> Result<String, String> {
            *index += 1;
            arguments.get(*index).cloned().ok_or_else(|| format!("{name} needs a value"))
        };
        match value.as_str() {
            "--live" => {}
            "--json" => json_output = true,
            "--format" => {
                let format = match next(&mut index, "--format") {
                    Ok(value) => value,
                    Err(error) => return print_error(error),
                };
                match format.as_str() {
                    "json" => json_output = true,
                    "text" => json_output = false,
                    _ => return print_error("--format must be json or text".into()),
                }
            }
            "--terminal" => {
                if live_target.is_some() {
                    return print_error("live explain target was supplied more than once".into());
                }
                live_target = Some(match next(&mut index, "--terminal") {
                    Ok(value) => value,
                    Err(error) => return print_error(error),
                });
            }
            "--process" => {
                process = Some(match next(&mut index, "--process") {
                    Ok(value) => value,
                    Err(error) => return print_error(error),
                })
            }
            "--screen" => {
                screen_path = Some(match next(&mut index, "--screen") {
                    Ok(value) => value,
                    Err(error) => return print_error(error),
                })
            }
            "--title" => {
                title = match next(&mut index, "--title") {
                    Ok(value) => value,
                    Err(error) => return print_error(error),
                }
            }
            "--progress" => {
                progress = match next(&mut index, "--progress") {
                    Ok(value) => value,
                    Err(error) => return print_error(error),
                }
            }
            _ if live && live_target.is_none() => live_target = Some(value.clone()),
            _ if live => return print_error(format!("unexpected live explain argument {value:?}")),
            _ if process.is_none() => process = Some(value.clone()),
            _ if screen_path.is_none() => screen_path = Some(value.clone()),
            _ => return print_error(format!("unexpected explain argument {value:?}")),
        }
        index += 1;
    }

    if live {
        if process.is_some() || screen_path.is_some() || !title.is_empty() || !progress.is_empty() {
            return print_error(
                "--live cannot be combined with --process, --screen, --title, or --progress"
                    .into(),
            );
        }
        let Some(target) = live_target else {
            return print_error(
                "usage: cmux-agent-screen-detection explain --live <terminal-id-or-title>"
                    .into(),
            );
        };
        let socket = match env::var("CMUX_TUI_SOCKET") {
            Ok(value) if !value.is_empty() => value,
            _ => return print_error("CMUX_TUI_SOCKET is required for live explain".into()),
        };
        let session = env::var("CMUX_TUI_SESSION_ID").unwrap_or_else(|_| "main".into());
        return match cmux_agent_screen_detection::diagnostics::explain_live(
            &socket, &session, &target,
        ) {
            Ok(value) if json_output => print_json(&value),
            Ok(value) => print_explain_text(&value),
            Err(error) => print_error(error),
        };
    }

    let Some(process) = process else {
        return print_error(explain_file_usage());
    };
    let Some(screen_path) = screen_path else {
        return print_error(explain_file_usage());
    };
    let screen = match cmux_agent_screen_detection::manifest::read_bounded_utf8_file(
        Path::new(&screen_path),
        MAX_EXPLAIN_SCREEN_BYTES,
    ) {
        Ok(screen) => screen,
        Err(error) => return print_error(format!("read screen {screen_path}: {error}")),
    };
    match cmux_agent_screen_detection::manifest::ManifestSet::from_environment() {
        Ok(set) => {
            let value = serde_json::to_value(set.explain(
                &process,
                cmux_agent_screen_detection::manifest::DetectionInput {
                    screen: &screen,
                    osc_title: &title,
                    osc_progress: &progress,
                },
            ))
            .expect("detection explanation is serializable");
            if json_output { print_json(&value) } else { print_explain_text(&value) }
        }
        Err(error) => print_error(error),
    }
}

fn explain_file_usage() -> String {
    "usage: cmux-agent-screen-detection explain <process> <screen-file> [--title <text>] [--progress <text>] [--format json|text]"
        .into()
}

fn run_update(arguments: Vec<String>) -> ExitCode {
    let mut url = None;
    let mut cache_dir = None;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--url" => {
                index += 1;
                let Some(value) = arguments.get(index) else {
                    return print_error("--url needs a value".into());
                };
                url = Some(value.clone());
            }
            "--cache-dir" => {
                index += 1;
                let Some(value) = arguments.get(index) else {
                    return print_error("--cache-dir needs a value".into());
                };
                cache_dir = Some(value.clone());
            }
            value => return print_error(format!("unexpected update argument {value:?}")),
        }
        index += 1;
    }
    let url =
        url.unwrap_or_else(cmux_agent_screen_detection::manifest_update::environment_catalog_url);
    let cache_dir = cache_dir
        .map(std::path::PathBuf::from)
        .unwrap_or_else(cmux_agent_screen_detection::manifest_update::environment_cache_dir);
    match cmux_agent_screen_detection::manifest_update::update_catalog(&url, &cache_dir) {
        Ok(summary) => {
            print_json(&cmux_agent_screen_detection::manifest_update::summary_json(&summary))
        }
        Err(error) => print_error(error),
    }
}

fn print_json(value: &serde_json::Value) -> ExitCode {
    match serde_json::to_string_pretty(value) {
        Ok(value) => {
            println!("{value}");
            ExitCode::SUCCESS
        }
        Err(error) => print_error(format!("encode JSON: {error}")),
    }
}

fn print_error(error: String) -> ExitCode {
    eprintln!("cmux-agent-screen-detection: {error}");
    ExitCode::FAILURE
}

fn print_explain_text(value: &serde_json::Value) -> ExitCode {
    println!(
        "terminal: {} ({})",
        value["terminal_id"].as_str().unwrap_or("file"),
        value["terminal_title"].as_str().unwrap_or("-")
    );
    println!("agent: {}", value["agent"].as_str().unwrap_or("unknown"));
    println!("state: {}", value["state"].as_str().unwrap_or("unknown"));
    println!(
        "manifest: {} {}",
        value["source"].as_str().unwrap_or("none"),
        value["version"].as_str().unwrap_or("unknown")
    );
    if let Some(rule) = value["matched_rule"].as_str() {
        println!("rule: {rule}");
    } else {
        println!("rule: none");
    }
    if let Some(reason) = value["fallback_reason"].as_str() {
        println!("fallback_reason: {reason}");
    }
    if let Some(process) = value["process"].as_object() {
        println!(
            "process: {} pid={} source={}",
            process["foreground_executable"]
                .as_str()
                .or_else(|| process["executable"].as_str())
                .unwrap_or("unknown"),
            process["pid"].as_u64().unwrap_or(0),
            process["identity_source"].as_str().unwrap_or("unknown")
        );
    }
    if let Some(screen) = value["screen"].as_object() {
        println!(
            "screen: {}x{} revision={}",
            screen["cols"].as_u64().unwrap_or(0),
            screen["rows"].as_u64().unwrap_or(0),
            screen["revision"].as_u64().unwrap_or(0)
        );
    }
    ExitCode::SUCCESS
}

fn print_help() {
    eprintln!(
        "usage:\n  cmux-agent-screen-detection\n  cmux-agent-screen-detection list\n  cmux-agent-screen-detection status\n  cmux-agent-screen-detection explain <process> <screen-file> [--title <text>] [--progress <text>] [--format json|text]\n  cmux-agent-screen-detection explain --live <terminal-id-or-title> [--format json|text]\n  cmux-agent-screen-detection update [--url <catalog-url>] [--cache-dir <path>]"
    );
}

#[cfg(test)]
mod tests {
    use super::required_plugin_id;

    #[test]
    fn plugin_id_requires_a_nonblank_supervisor_namespace() {
        assert!(required_plugin_id(None).is_err());
        assert!(required_plugin_id(Some(String::new())).is_err());
        assert!(required_plugin_id(Some("  ".into())).is_err());
        assert_eq!(required_plugin_id(Some("agent-screen".into())).unwrap(), "agent-screen");
    }

    #[test]
    fn plugin_id_rejects_values_that_cannot_name_a_journal_namespace() {
        let too_long = "a".repeat(65);
        for value in [
            "Screen-detector",
            "screen.detector",
            "screen detector",
            "-screen-detector",
            "cmux_agent",
        ] {
            assert!(
                required_plugin_id(Some(value.to_string())).is_err(),
                "invalid plugin id was accepted: {value:?}"
            );
        }
        assert!(required_plugin_id(Some(too_long)).is_err());
        assert!(required_plugin_id(Some("screen_detector-2".into())).is_ok());
    }
}
