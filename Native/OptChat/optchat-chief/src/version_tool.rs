//! The Chief's `version` tool (Lawrence 2026-10-20: "make sure chief can
//! detect cmux version and stuff like that"). One read-only call answers:
//!
//! - `cmux`: `cmux version --json` of the CLI the host put first on PATH
//!   (cmux_env.rs): the CLI, the app behind its socket (full nightly
//!   version, channel, build sha, bundle, pid), whether the CLI is that app's
//!   own, the update state, the bundled acpmux/Chief/cmux-tui stamps and
//!   macOS. When that fails (no app is fine: the CLI still answers; an older
//!   CLI without `version` is not), `{"error": …}` says why.
//! - `chief`: this binary's version and path, and the engine the host
//!   resolved at its start (engine-resolved.json: each role's harness, CLI
//!   path and `--version`).

use std::path::Path;
use std::process::Command;

use serde_json::{Value, json};

/// The tool's answer: the cmux report from `cmux`, the Chief's from `home`.
pub fn report(cmux: &dyn Fn() -> Result<Value, String>, home: &Path) -> Value {
    let cmux = cmux().unwrap_or_else(|error| json!({ "error": error }));
    let engine = crate::engine::load_resolved(home)
        .and_then(|resolved| serde_json::to_value(resolved).ok())
        .unwrap_or(Value::Null);
    json!({
        "cmux": cmux,
        "chief": {
            "version": env!("CARGO_PKG_VERSION"),
            "path": std::env::current_exe().ok().map(|path| path.display().to_string()),
            "engine": engine,
        },
    })
}

/// `cmux version --json`, run as the Chief's shell would run it.
pub fn run_cmux_version() -> Result<Value, String> {
    let output = Command::new("cmux")
        .args(["version", "--json"])
        .output()
        .map_err(|error| format!("cmux: {error}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let reason = [stderr.trim(), stdout.trim()]
            .into_iter()
            .find(|text| !text.is_empty())
            .unwrap_or("no output");
        return Err(format!(
            "cmux version --json exited {}: {reason}",
            output.status
        ));
    }
    serde_json::from_str(stdout.trim()).map_err(|error| format!("cmux version --json: {error}"))
}

/// The tool's text: the report as one JSON line.
pub fn answer(home: &Path) -> String {
    report(&run_cmux_version, home).to_string()
}
