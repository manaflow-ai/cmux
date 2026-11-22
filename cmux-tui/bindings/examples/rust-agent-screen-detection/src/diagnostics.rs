//! Read-only diagnostics for a live terminal.
//!
//! Herdr's live `agent explain` command is useful when a row is wrong. The
//! equivalent belongs in this package because process identity, manifests,
//! and state interpretation are plugin policy. The daemon is used only for
//! the generic terminal list, process, and screen reads.

#[cfg(test)]
mod target_selection_tests {
    use std::collections::BTreeMap;

    use cmux::{TerminalId, TerminalLifecycle, TerminalSnapshot};

    use super::resolve_snapshot;

    fn snapshot(hex: &str, title: &str) -> TerminalSnapshot {
        TerminalSnapshot {
            id: TerminalId::parse(format!("term_{hex}"))
                .expect("test terminal ID has the required shape"),
            tab_ids: Vec::new(),
            title: title.to_string(),
            cwd: None,
            cols: 80,
            rows: 24,
            running: true,
            lifecycle: TerminalLifecycle::Running,
            stream_revision: Some(1),
            exit: None,
            extra: BTreeMap::new(),
        }
    }

    #[test]
    fn live_target_accepts_an_exact_terminal_id() {
        let terminals = vec![snapshot("11111111111111111111111111111111", "build")];
        let selected = resolve_snapshot(&terminals, "term_11111111111111111111111111111111")
            .expect("terminal ID should resolve");
        assert_eq!(selected.title, "build");
    }

    #[test]
    fn live_target_rejects_an_ambiguous_title() {
        let terminals = vec![
            snapshot("11111111111111111111111111111111", "agent"),
            snapshot("22222222222222222222222222222222", "agent"),
        ];
        let error = resolve_snapshot(&terminals, "agent").expect_err("duplicate title must fail");
        assert!(error.contains("more than one terminal"), "{error}");
        assert!(error.contains("term_1111"), "{error}");
        assert!(error.contains("term_2222"), "{error}");
    }
}
use std::path::{Path, PathBuf};

use cmux::{
    Client, Config, ProcessInfoResult, ReadScreenOptions, Selector, SessionId, TerminalId,
    TerminalSnapshot,
};
use serde_json::{Value, json};

use crate::manifest::{DetectionInput, ManifestSet};
use crate::process;

const MAX_TARGET_BYTES: usize = 256;

/// Where a live explain connects, and the session it names there.
#[derive(Debug, PartialEq, Eq)]
pub struct LiveRoute {
    /// The daemon socket.
    pub socket: PathBuf,
    /// The session id or name to read; `None` reads the socket's own session.
    pub session: Option<String>,
}

/// Resolve the daemon the way the `cmux` CLI does: `--socket` is exact;
/// `--session NAME` derives that session's socket, and a socket the shell
/// inherited from a cmux terminal (`CMUX_TUI_SOCKET`) does not redirect it;
/// with neither, the inherited socket (`CMUX_TUI_SOCKET`, then
/// `CMUX_MUX_SOCKET`) and its `CMUX_TUI_SESSION_ID`, else the `main`
/// session's socket. `env` reads one environment variable.
pub fn live_route(
    socket: Option<&str>,
    session: Option<&str>,
    env: impl Fn(&str) -> Option<String>,
) -> Result<LiveRoute, String> {
    let env = |name: &str| env(name).filter(|value| !value.is_empty());
    if let Some(name) = session {
        validate_session_name(name)?;
    }
    if let Some(socket) = socket {
        if socket.is_empty() {
            return Err("--socket must not be empty".into());
        }
        return Ok(LiveRoute { socket: socket.into(), session: session.map(str::to_owned) });
    }
    if let Some(name) = session {
        return Ok(LiveRoute {
            socket: cmux::raw::default_socket_path(name),
            session: Some(name.to_owned()),
        });
    }
    match env("CMUX_TUI_SOCKET").or_else(|| env("CMUX_MUX_SOCKET")) {
        Some(socket) => {
            Ok(LiveRoute { socket: socket.into(), session: env("CMUX_TUI_SESSION_ID") })
        }
        None => Ok(LiveRoute { socket: cmux::raw::default_socket_path("main"), session: None }),
    }
}

/// The SDK's rule for a session name in a socket path: one non-empty path
/// component without separators or control characters.
fn validate_session_name(name: &str) -> Result<(), String> {
    let invalid = name.is_empty()
        || matches!(name, "." | "..")
        || name.chars().any(|character| {
            matches!(character, '/' | '\\' | '\0' | '\u{0085}' | '\u{2028}' | '\u{2029}')
                || character.is_control()
        });
    if invalid {
        return Err(format!("--session {name:?} is not a session name"));
    }
    Ok(())
}

/// Explain one live terminal selected by its opaque ID or exact title.
///
/// The operation is read-only. It never registers a producer, appends a
/// journal event, changes terminal scroll position, or sends input.
/// `session_name` `None` reads the session the socket serves.
pub fn explain_live(
    socket: &Path,
    session_name: Option<&str>,
    target: &str,
) -> Result<Value, String> {
    validate_target(target)?;
    let session_selector = match session_name {
        Some(name) => session_selector(name)?,
        None => Selector::current(),
    };
    let client = Client::connect(Config::from_socket_path(socket))
        .map_err(|error| format!("connect to cmux: {error}"))?;
    let session = client.session(session_selector);
    let snapshots = session.terminal_snapshots().map_err(|error| error.to_string())?;
    let snapshot = resolve_snapshot(&snapshots, target)?;
    let terminal = session.terminal(snapshot.id.clone());
    let process_info = terminal.process().map_err(|error| error.to_string())?;
    let screen = terminal.read_screen(ReadScreenOptions).map_err(|error| error.to_string())?;

    let (manifests, manifest_warning) = match ManifestSet::from_environment() {
        Ok(set) => (set, None),
        Err(error) => {
            eprintln!("cmux-agent-screen-detection: optional manifest source ignored: {error}");
            (ManifestSet::bundled().clone(), Some(error))
        }
    };

    let native_job = process::foreground_job(process_info.pid);
    let process_group_authoritative = native_job.is_some();
    let job = native_job.unwrap_or_else(|| process::fallback_job(&process_info));
    // Do not label the one-process SDK fallback as a native process-group
    // result. The fallback job uses the terminal's reported PID as a synthetic
    // group ID, so its identity is useful but not authoritative.
    let group_identified =
        process_group_authoritative.then(|| process::identify_job(&manifests, &job)).flatten();
    let group_identity_available = group_identified.is_some();
    let identified = group_identified
        .or_else(|| process::identify_job_with_process_fallback(&manifests, &job, &process_info));
    let primary_process_name = process_name(&process_info);
    let (identified_process_name, identity_source) = identified
        .map(|(_, candidate)| {
            (
                candidate,
                if group_identity_available {
                    "foreground_process_group"
                } else {
                    "sdk_process_fallback"
                },
            )
        })
        .unwrap_or((primary_process_name, "sdk_process_fallback"));

    let explanation = manifests.explain(
        &identified_process_name,
        DetectionInput {
            screen: &screen.text,
            // The scanner uses the same generic title and OSC progress fields.
            // A one-shot explain has no earlier revision to compare, so it
            // reports the metadata and its freshness limitation explicitly.
            osc_title: &snapshot.title,
            osc_progress: screen.osc_progress.as_deref().unwrap_or_default(),
        },
    );
    let mut output = serde_json::to_value(explanation)
        .map_err(|error| format!("encode explanation: {error}"))?;
    let object = output
        .as_object_mut()
        .ok_or_else(|| "explanation did not encode as an object".to_string())?;
    object.insert("terminal_id".into(), json!(snapshot.id.as_str()));
    object.insert("terminal_title".into(), json!(snapshot.title.clone()));
    object.insert("terminal_lifecycle".into(), json!(lifecycle_name(snapshot)));
    object.insert(
        "process".into(),
        json!({
            "pid": process_info.pid,
            "executable": process_info.executable,
            "foreground_executable": process_info.foreground_executable,
            "foreground_cwd": process_info.foreground_cwd,
            "identity_source": identity_source,
            "process_group_authoritative": process_group_authoritative,
        }),
    );
    object.insert(
        "screen".into(),
        json!({
            "source": "terminal.screen.read",
            "viewport": "live_bottom",
            "revision": screen.revision.or(snapshot.stream_revision),
            "cols": screen.cols,
            "rows": screen.rows,
            "cursor_row": screen.cursor_row,
            "cursor_col": screen.cursor_col,
            "cursor_visible": screen.cursor_visible,
            "osc_progress_present": screen
                .osc_progress
                .as_deref()
                .is_some_and(|progress| !progress.is_empty()),
            "metadata_freshness": "one_shot_unknown",
        }),
    );
    if let Some(warning) = manifest_warning {
        object.insert("manifest_load_warning".into(), json!(warning));
    }
    Ok(output)
}

fn validate_target(target: &str) -> Result<(), String> {
    if target.is_empty() {
        return Err("live explain target must not be empty".into());
    }
    if target.len() > MAX_TARGET_BYTES {
        return Err(format!("live explain target exceeds {MAX_TARGET_BYTES} bytes"));
    }
    Ok(())
}

fn session_selector(session_name: &str) -> Result<Selector<SessionId>, String> {
    if session_name.trim().is_empty() {
        return Err("the session must not be empty".into());
    }
    match SessionId::parse(session_name.to_owned()) {
        Ok(id) => Ok(Selector::id(id)),
        Err(_) => Ok(Selector::name(session_name.to_owned())),
    }
}

/// Resolve an exact terminal ID or exact title. A title is not a stable
/// identity, so duplicate titles fail with actionable IDs instead of choosing
/// whichever catalog entry happened to arrive first.
pub(crate) fn resolve_snapshot<'a>(
    snapshots: &'a [TerminalSnapshot],
    target: &str,
) -> Result<&'a TerminalSnapshot, String> {
    if let Ok(id) = TerminalId::parse(target.to_owned()) {
        return snapshots
            .iter()
            .find(|snapshot| snapshot.id == id)
            .ok_or_else(|| format!("terminal {target:?} was not found"));
    }

    let matches = snapshots.iter().filter(|snapshot| snapshot.title == target).collect::<Vec<_>>();
    match matches.as_slice() {
        [] => Err(format!("no terminal has the exact title {target:?}")),
        [snapshot] => Ok(snapshot),
        many => {
            let ids =
                many.iter().map(|snapshot| snapshot.id.as_str()).collect::<Vec<_>>().join(", ");
            Err(format!("more than one terminal has the exact title {target:?}; use an ID: {ids}"))
        }
    }
}

fn process_name(process: &ProcessInfoResult) -> String {
    process
        .foreground_executable
        .clone()
        .or_else(|| process.executable.clone())
        .or_else(|| process.argv.first().cloned())
        .unwrap_or_else(|| "unknown".into())
}

fn lifecycle_name(snapshot: &TerminalSnapshot) -> &'static str {
    match snapshot.lifecycle {
        cmux::TerminalLifecycle::Launching => "launching",
        cmux::TerminalLifecycle::Running => "running",
        cmux::TerminalLifecycle::Exited => "exited",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn snapshot(hex: &str, title: &str) -> TerminalSnapshot {
        TerminalSnapshot {
            id: TerminalId::parse(format!("term_{hex}"))
                .expect("test terminal ID has the required shape"),
            tab_ids: Vec::new(),
            title: title.to_string(),
            cwd: None,
            cols: 80,
            rows: 24,
            running: true,
            lifecycle: cmux::TerminalLifecycle::Running,
            stream_revision: Some(1),
            exit: None,
            extra: BTreeMap::new(),
        }
    }

    #[test]
    fn target_rejects_an_empty_or_oversized_value() {
        assert!(validate_target("").is_err());
        assert!(validate_target(&"x".repeat(MAX_TARGET_BYTES + 1)).is_err());
    }

    #[test]
    fn target_reports_missing_ids_and_titles() {
        let terminals = vec![snapshot("11111111111111111111111111111111", "build")];
        assert!(
            resolve_snapshot(&terminals, "term_22222222222222222222222222222222")
                .unwrap_err()
                .contains("was not found")
        );
        assert!(resolve_snapshot(&terminals, "missing").unwrap_err().contains("no terminal has"));
    }

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |name| pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).into())
    }

    const IN_A_PANE: &[(&str, &str)] =
        &[("CMUX_TUI_SOCKET", "/tmp/pane.sock"), ("CMUX_TUI_SESSION_ID", "pane-session")];

    #[test]
    fn live_session_derives_its_socket_like_the_cli_and_ignores_the_panes() {
        let route = live_route(None, Some("w4i-e1"), env(IN_A_PANE)).unwrap();
        assert_eq!(route.socket, cmux::raw::default_socket_path("w4i-e1"));
        assert_ne!(route.socket, PathBuf::from("/tmp/pane.sock"));
        assert_eq!(route.session.as_deref(), Some("w4i-e1"));
    }

    #[test]
    fn live_socket_is_exact_and_reads_its_own_session() {
        let route = live_route(Some("/tmp/exact.sock"), None, env(IN_A_PANE)).unwrap();
        assert_eq!(route, LiveRoute { socket: "/tmp/exact.sock".into(), session: None });
        let both = live_route(Some("/tmp/exact.sock"), Some("w4i"), env(&[])).unwrap();
        assert_eq!(both.session.as_deref(), Some("w4i"));
    }

    #[test]
    fn live_route_without_flags_keeps_the_panes_socket_else_main() {
        let route = live_route(None, None, env(IN_A_PANE)).unwrap();
        assert_eq!(route.socket, PathBuf::from("/tmp/pane.sock"));
        assert_eq!(route.session.as_deref(), Some("pane-session"));
        let mux = live_route(None, None, env(&[("CMUX_MUX_SOCKET", "/tmp/mux.sock")])).unwrap();
        assert_eq!(mux, LiveRoute { socket: "/tmp/mux.sock".into(), session: None });
        let bare = live_route(None, None, env(&[])).unwrap();
        assert_eq!(bare.socket, cmux::raw::default_socket_path("main"));
    }

    #[test]
    fn live_session_names_a_path_component() {
        for name in ["", "..", "a/b", "a\nb"] {
            assert!(live_route(None, Some(name), env(&[])).is_err(), "{name:?}");
        }
    }
}
