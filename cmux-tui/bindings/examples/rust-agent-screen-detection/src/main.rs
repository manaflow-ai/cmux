use std::env;
use std::fs::File;
use std::io::{self, Read};
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
        _ => {
            eprintln!("cmux-agent-screen-detection: CMUX_PLUGIN_ID is required");
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

fn required_plugin_id(value: Option<String>) -> Result<String, &'static str> {
    match value {
        Some(value) if !value.trim().is_empty() => Ok(value),
        _ => Err("CMUX_PLUGIN_ID is required"),
    }
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
    let mut process = None;
    let mut screen_path = None;
    let mut title = String::new();
    let mut progress = String::new();
    let mut index = 0;
    while index < arguments.len() {
        let value = &arguments[index];
        let next = |index: &mut usize, name: &str| -> Result<String, String> {
            *index += 1;
            arguments.get(*index).cloned().ok_or_else(|| format!("{name} needs a value"))
        };
        match value.as_str() {
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
            _ if process.is_none() => process = Some(value.clone()),
            _ if screen_path.is_none() => screen_path = Some(value.clone()),
            _ => return print_error(format!("unexpected explain argument {value:?}")),
        }
        index += 1;
    }
    let Some(process) = process else {
        return print_error("usage: cmux-agent-screen-detection explain <process> <screen-file> [--title <text>] [--progress <text>]".into());
    };
    let Some(screen_path) = screen_path else {
        return print_error("usage: cmux-agent-screen-detection explain <process> <screen-file> [--title <text>] [--progress <text>]".into());
    };
    let screen = match read_bounded_utf8_file(&screen_path, MAX_EXPLAIN_SCREEN_BYTES) {
        Ok(screen) => screen,
        Err(error) => return print_error(format!("read screen {screen_path}: {error}")),
    };
    match cmux_agent_screen_detection::manifest::ManifestSet::from_environment() {
        Ok(set) => print_json(
            &serde_json::to_value(set.explain(
                &process,
                cmux_agent_screen_detection::manifest::DetectionInput {
                    screen: &screen,
                    osc_title: &title,
                    osc_progress: &progress,
                },
            ))
            .expect("detection explanation is serializable"),
        ),
        Err(error) => print_error(error),
    }
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

fn read_bounded_utf8_file(path: &str, max_bytes: usize) -> io::Result<String> {
    let file = File::open(path)?;
    let mut bytes = Vec::with_capacity(max_bytes.min(8 * 1024));
    file.take(u64::try_from(max_bytes).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file exceeds {max_bytes} bytes"),
        ));
    }
    String::from_utf8(bytes).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn print_help() {
    eprintln!(
        "usage:\n  cmux-agent-screen-detection\n  cmux-agent-screen-detection list\n  cmux-agent-screen-detection status\n  cmux-agent-screen-detection explain <process> <screen-file> [--title <text>] [--progress <text>]\n  cmux-agent-screen-detection update [--url <catalog-url>] [--cache-dir <path>]"
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
}
