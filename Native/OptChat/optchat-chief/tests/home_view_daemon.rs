//! The Chief's live view of the person's Home workspace (cx-ebm.59.2, Lawrence 2026-10-14:
//! "chief needs to be able to have live context on what's happening on right side"). Against a
//! real headless cmux-tui daemon (`CMUX_TUI_BIN`) with a Home workspace (`workspace.ensure_home`,
//! as the app sends it) holding a terminal that printed a line, `optchat-chief workspace` (the
//! same reader every turn uses, through the bundled CLI the host pins: `bin/cmux`, beside
//! `bin/cmux-tui`, as the app ships them) prints one block that names the
//! Home workspace, its pane, tab and terminal by their public ids and shows the terminal's last
//! screen lines. A terminal of another workspace is not in it. A daemon with no Home workspace
//! gives no block.
//!
//! Run: `CMUX_TUI_BIN=<cmux-tui target>/debug/cmux-tui cargo test --test home_view_daemon --
//! --ignored`.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

fn bin() -> PathBuf {
    PathBuf::from(std::env::var("CMUX_TUI_BIN").expect("CMUX_TUI_BIN names a cmux-tui binary"))
}

/// A headless daemon in its own home; stopped (by its own CLI) on drop.
struct Daemon {
    dir: tempfile::TempDir,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::Builder::new()
            .prefix("ohv")
            .tempdir_in("/tmp")
            .unwrap();
        let socket = dir.path().join("d.sock");
        let daemon = Daemon { dir, socket };
        let out = daemon.cmux(&["daemon", "ensure"]);
        assert!(out.status.success(), "daemon ensure: {out:?}");
        daemon
    }

    fn env(&self, command: &mut Command) {
        let home = self.dir.path();
        command
            .env("HOME", home)
            .env("TMPDIR", home)
            .env("CMUX_TUI_STATE_DIR", home.join("state"))
            .env("CMUX_TUI_SOCKET", &self.socket)
            .env_remove("CMUX_MUX_SOCKET")
            .env("LC_ALL", "C");
    }

    fn cmux(&self, args: &[&str]) -> Output {
        let mut command = Command::new(bin());
        self.env(&mut command);
        command
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .stdin(Stdio::null());
        command.output().unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let out = self.cmux(args);
        assert!(out.status.success(), "cmux {args:?}: {out:?}");
        serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|e| panic!("cmux {args:?}: {e}: {out:?}"))
    }

    /// One `cmux.protocol/2` mutation on a fresh connection; its result.
    fn mutate(&self, operation: &str, key: &str, params: Value) -> Value {
        let session = self.json(&["--json", "session", "current", "show"]);
        let mut params = params;
        params["machine"] = session["machine_id"].clone();
        params["session"] = session["id"].clone();
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut writer = stream.try_clone().unwrap();
        let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": key,
            "operation": operation, "idempotency_key": key, "params": params});
        writeln!(writer, "{request}").unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply["ok"], true, "{operation}: {reply}");
        reply["result"].clone()
    }

    /// A terminal tab in `workspace` that printed `marker`: (pane, tab, terminal).
    fn terminal_printing(
        &self,
        workspace: &str,
        key: &str,
        marker: &str,
    ) -> (String, String, String) {
        let created = self.json(&[
            "--json",
            "tab",
            "create",
            "terminal",
            "--workspace",
            workspace,
            "--correlation-key",
            key,
        ]);
        let value = &created["value"];
        let id = |k: &str| {
            value[k]
                .as_str()
                .unwrap_or_else(|| panic!("no {k}: {created}"))
                .to_owned()
        };
        let (pane, tab, terminal) = (id("pane_id"), id("tab_id"), id("terminal_id"));
        // The shell computes the marker, so the typed command line never matches it.
        let (head, n) = marker.rsplit_once('-').unwrap();
        let n: u64 = n.parse().unwrap();
        let text = format!("echo {head}-$(({} + 1))\n", n - 1);
        let out = self.cmux(&["terminal", &terminal, "write", "--text", &text]);
        assert!(out.status.success(), "write: {out:?}");
        let waited = self.json(&[
            "--json",
            "terminal",
            &terminal,
            "screen",
            "wait",
            "--pattern",
            marker,
            "--timeout-ms",
            "10000",
        ]);
        assert_eq!(
            waited["matched"], true,
            "the terminal never printed {marker}: {waited}"
        );
        (pane, tab, terminal)
    }

    /// The app bundle's bin dir as the app ships it: one binary as `cmux` (the curated CLI)
    /// and as `cmux-tui`. The host pins `CMUX_BUNDLED_CLI_PATH` to its `cmux`.
    fn bundle_cli(&self) -> PathBuf {
        let dir = self.dir.path().join("bundle/bin");
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["cmux", "cmux-tui"] {
            let link = dir.join(name);
            if !link.exists() {
                std::os::unix::fs::symlink(bin(), &link).unwrap();
            }
        }
        dir.join("cmux")
    }

    /// `optchat-chief workspace` with this daemon's CLI, pinned as the host pins it (the
    /// bundle's `cmux`): its exit code and stdout.
    fn chief_workspace(&self) -> (Option<i32>, String) {
        let cli = self.bundle_cli();
        let mut command = Command::new(env!("CARGO_BIN_EXE_optchat-chief"));
        self.env(&mut command);
        command
            .env("CMUX_BUNDLED_CLI_PATH", cli)
            .arg("workspace")
            .stdin(Stdio::null());
        let out = command.output().unwrap();
        (
            out.status.code(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        )
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.cmux(&["daemon", "stop", "--end-terminals"]);
    }
}

fn home_workspace(daemon: &Daemon) -> String {
    let result = daemon.mutate("workspace.ensure_home", "ohv-home", json!({}));
    result["value"]["workspace_id"]
        .as_str()
        .unwrap_or_else(|| panic!("ensure_home: {result}"))
        .to_owned()
}

#[test]
#[ignore = "needs CMUX_TUI_BIN (a built cmux-tui)"]
fn chief_workspace_shows_the_home_workspace_panes_tabs_and_terminal_tail() {
    let daemon = Daemon::start();
    let home = home_workspace(&daemon);
    let (pane, tab, terminal) = daemon.terminal_printing(&home, "ohv-term", "HOMEVIEW-42");
    // Another workspace's terminal is not the person's Home.
    let other = daemon.json(&[
        "--json",
        "workspace",
        "create",
        "--name",
        "elsewhere",
        "--correlation-key",
        "ohv-ws",
    ]);
    let other = other["value"]["workspace_id"]
        .as_str()
        .unwrap_or_else(|| panic!("{other}"))
        .to_owned();
    let _ = daemon.terminal_printing(&other, "ohv-other", "ELSEWHERE-7");

    // The person looks at Home (making the other workspace may have selected it).
    let focused = daemon.cmux(&["workspace", &home, "focus"]);
    assert!(focused.status.success(), "workspace focus: {focused:?}");

    let (code, out) = daemon.chief_workspace();
    assert_eq!(code, Some(0), "chief workspace failed: {out}");
    assert!(
        out.starts_with(&format!("<cmux-home-workspace workspace={home} ")),
        "{out}"
    );
    assert!(out.trim_end().ends_with("</cmux-home-workspace>"), "{out}");
    assert!(
        out.contains(&format!("pane {pane} (focused)")),
        "the focused pane: {out}"
    );
    assert!(
        out.contains(&format!("{tab} terminal {terminal} ")),
        "the terminal tab: {out}"
    );
    assert!(out.contains("[shown]"), "the shown tab: {out}");
    assert!(
        out.lines()
            .any(|line| line.starts_with("    | ") && line.trim_end().ends_with("HOMEVIEW-42")),
        "the terminal's screen tail: {out}"
    );
    assert!(
        !out.contains("ELSEWHERE-7") && !out.contains(&other),
        "another workspace leaked in: {out}"
    );
    assert!(
        out.len() <= 6 * 1024,
        "the block is bounded: {} bytes",
        out.len()
    );
}

#[test]
#[ignore = "needs CMUX_TUI_BIN (a built cmux-tui)"]
fn chief_workspace_gives_no_block_without_a_home_workspace() {
    let daemon = Daemon::start();
    let workspace = daemon.json(&[
        "--json",
        "workspace",
        "create",
        "--name",
        "plain",
        "--correlation-key",
        "ohv-p",
    ]);
    let workspace = workspace["value"]["workspace_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let _ = daemon.terminal_printing(&workspace, "ohv-pt", "PLAIN-3");
    let (code, out) = daemon.chief_workspace();
    assert_eq!(code, Some(1), "no Home workspace is not a block: {out}");
    assert!(
        !out.contains("cmux-home-workspace") && !out.contains("PLAIN-3"),
        "{out}"
    );
}
