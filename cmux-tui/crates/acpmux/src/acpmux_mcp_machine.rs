//! The `acpmux` MCP server's machine tools: `machine_read`, `machine_edit`, `machine_exec`, one
//! file or command action on another of the person's signed-in machines. An agent whose loop
//! runs on one machine (a VM) uses them for what lives on another (the Mac the person sits at):
//! each call runs where its data is. The daemon sends the call on (`_acpmux/machine_files_call`,
//! `server/machine_files_relay.rs`); the far machine's grant and policy decide it
//! (`machine_files.rs`). Three tools, so the harness's permission prompt tells a read from an
//! edit from a command.

use super::{arg, error_result, ok, refusal};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) const TOOLS: &[&str] = &["machine_read", "machine_edit", "machine_exec"];

pub(super) fn tools() -> Vec<Value> {
    let machine = json!({"type": "string", "description": "The machine's name, as `cmux machines` or list_machines shows it."});
    vec![
        json!({
            "name": "machine_read",
            "description": "Read on another of the person's signed-in machines (their Mac, from an agent on a VM): a file's text, a folder's entries, files matching a glob, or lines matching a regex. For this machine use your own tools. Paths are absolute, in that machine's home or temp folders. That machine must allow control (Settings > Devices); a refusal says what is missing.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "machine": machine,
                    "op": {"type": "string", "enum": ["read", "list", "glob", "grep"], "description": "read (default): a file's text and sha256. list: a folder. glob: paths under path matching pattern. grep: lines under path matching the regex pattern."},
                    "path": {"type": "string", "description": "The file, or the folder to list or search."},
                    "pattern": {"type": "string", "description": "glob: a glob such as **/*.swift. grep: a regex."},
                    "glob": {"type": "string", "description": "grep: only files matching this glob."},
                    "limit": {"type": "integer", "minimum": 1, "description": "glob, grep: at most this many results."},
                    "start_line": {"type": "integer", "minimum": 1},
                    "end_line": {"type": "integer", "minimum": 1}
                },
                "required": ["machine", "path"]
            }
        }),
        json!({
            "name": "machine_edit",
            "description": "Change a file on another of the person's signed-in machines: write its whole text, replace exact strings in it, or apply a unified diff. An edit names the sha256 machine_read gave, so a file changed since is not overwritten. Its cmux files, system paths, credentials and startup files are refused.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "machine": machine,
                    "path": {"type": "string", "description": "The file (write, edits)."},
                    "text": {"type": "string", "description": "Write: the file's whole new text."},
                    "edits": {"type": "array", "items": {"type": "object", "properties": {"old": {"type": "string"}, "new": {"type": "string"}}, "required": ["old", "new"]}, "description": "Edit: each old string, found once, becomes new."},
                    "expect_sha256": {"type": "string", "description": "The file's sha256 from machine_read: required with edits, optional with text."},
                    "patch": {"type": "string", "description": "A unified diff, applied under cwd."},
                    "cwd": {"type": "string", "description": "Patch: the folder its paths are relative to."}
                },
                "required": ["machine"]
            }
        }),
        json!({
            "name": "machine_exec",
            "description": "Run one command on another of the person's signed-in machines and return its exit code, stdout and stderr (each up to 256 KB). Only for what that machine alone can do; build and test here. Timeout two minutes by default, at most ten. Destructive commands and ones that touch credentials are refused there.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "machine": machine,
                    "command": {"type": "string", "description": "A shell command line, run by /bin/sh -c."},
                    "argv": {"type": "array", "items": {"type": "string"}, "minItems": 1, "description": "Instead of command: the program and its arguments, run with no shell."},
                    "cwd": {"type": "string", "description": "Its folder, absolute, inside that machine's home or a temp folder (not home itself). Default: that machine's work folder."},
                    "timeout_ms": {"type": "integer", "minimum": 1}
                },
                "required": ["machine"]
            }
        }),
    ]
}

/// The daemon request for a call (`{machine, action, params}`), or the refusal the agent reads.
pub(super) fn request(name: &str, args: &Value) -> Result<Value, String> {
    let machine = arg(args, "machine").ok_or("machine is required")?;
    let copy = |keys: &[&str]| -> serde_json::Map<String, Value> {
        let mut out = serde_json::Map::new();
        for key in keys {
            if let Some(v) = args.get(*key).filter(|v| !v.is_null()) {
                out.insert((*key).to_owned(), v.clone());
            }
        }
        out
    };
    let path = || arg(args, "path").ok_or("path is required");
    let (action, params) = match name {
        "machine_read" => match arg(args, "op").unwrap_or("read") {
            "read" => ("fs.read", copy(&["path", "start_line", "end_line"])),
            "list" => ("fs.list", copy(&["path"])),
            op @ ("glob" | "grep") => {
                let mut p = copy(&["pattern", "glob", "limit"]);
                p.insert("root".to_owned(), json!(path()?));
                if !p.contains_key("pattern") {
                    return Err(format!("{op} needs pattern"));
                }
                (if op == "glob" { "fs.glob" } else { "fs.grep" }, p)
            }
            other => return Err(format!("unknown op {other:?}: read, list, glob or grep")),
        },
        "machine_edit" => {
            let has = |key: &str| args.get(key).is_some_and(|v| !v.is_null());
            match (has("text"), has("edits"), has("patch")) {
                (true, false, false) => ("fs.write", copy(&["path", "text", "expect_sha256"])),
                (false, true, false) => ("fs.edit", copy(&["path", "edits", "expect_sha256"])),
                (false, false, true) => ("fs.patch", copy(&["patch", "cwd"])),
                _ => return Err("give exactly one of text, edits or patch".to_owned()),
            }
        }
        "machine_exec" => {
            let mut p = copy(&["argv", "cwd", "timeout_ms"]);
            match (args.get("command").and_then(Value::as_str), p.get("argv").is_some()) {
                (Some(line), false) if !line.trim().is_empty() => {
                    p.insert("argv".to_owned(), json!(["/bin/sh", "-c", line]));
                }
                (None, true) => {}
                _ => return Err("give exactly one of command or argv".to_owned()),
            }
            ("exec", p)
        }
        other => return Err(format!("unknown tool {other}")),
    };
    if matches!(action, "fs.read" | "fs.list" | "fs.write" | "fs.edit") {
        path()?;
    }
    Ok(json!({"machine": machine, "action": action, "params": params}))
}

/// What the agent reads for an answer: a file's text, a command's output, else the JSON.
pub(super) fn text(action: &str, reply: &Value) -> String {
    let s = |key: &str| reply.get(key).and_then(Value::as_str).unwrap_or_default();
    match action {
        "fs.read" => format!("{}\n[sha256 {}]", s("text"), s("sha256")),
        "exec" => {
            let mut out = match reply.get("exit").and_then(Value::as_i64) {
                Some(code) => format!("exit {code}"),
                None if reply.get("timed_out") == Some(&Value::Bool(true)) => {
                    "timed out".to_owned()
                }
                None => "ended by a signal".to_owned(),
            };
            if reply.get("truncated") == Some(&Value::Bool(true)) {
                out.push_str(" (output cut at 256 KB per stream)");
            }
            for (label, key) in [("stdout", "stdout"), ("stderr", "stderr")] {
                if !s(key).is_empty() {
                    out.push_str(&format!("\n--- {label}\n{}", s(key).trim_end()));
                }
            }
            out
        }
        _ => serde_json::to_string_pretty(reply).unwrap_or_else(|_| reply.to_string()),
    }
}

pub(super) async fn call(daemon: &Arc<Client>, name: &str, args: &Value) -> Value {
    let params = match request(name, args) {
        Ok(p) => p,
        Err(e) => return error_result(e),
    };
    let action = params.get("action").and_then(Value::as_str).unwrap_or_default().to_owned();
    match daemon.request(method::MUX_MACHINE_FILES_CALL, params).await {
        Ok(reply) => ok(text(&action, &reply), reply),
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_tools_name_one_action_each() {
        let r = request("machine_read", &json!({"machine": "mac", "path": "/tmp/a"})).unwrap();
        assert_eq!(r, json!({"machine": "mac", "action": "fs.read", "params": {"path": "/tmp/a"}}));
        let r = request(
            "machine_read",
            &json!({"machine": "mac", "op": "grep", "path": "/tmp", "pattern": "x", "limit": 5}),
        )
        .unwrap();
        assert_eq!(r["action"], "fs.grep");
        assert_eq!(r["params"], json!({"root": "/tmp", "pattern": "x", "limit": 5}));
        let r = request(
            "machine_edit",
            &json!({"machine": "mac", "path": "/tmp/a", "edits": [{"old": "a", "new": "b"}], "expect_sha256": "s"}),
        )
        .unwrap();
        assert_eq!(r["action"], "fs.edit");
        let r = request("machine_exec", &json!({"machine": "mac", "command": "uname -a"})).unwrap();
        assert_eq!(r["params"]["argv"], json!(["/bin/sh", "-c", "uname -a"]));
        let r = request("machine_exec", &json!({"machine": "mac", "argv": ["uname"]})).unwrap();
        assert_eq!(r["params"], json!({"argv": ["uname"]}));
        // A read tool never names a write or a command, whatever its arguments say.
        let r = request(
            "machine_read",
            &json!({"machine": "mac", "path": "/tmp/a", "text": "x", "argv": ["rm"], "_level": "full"}),
        )
        .unwrap();
        assert_eq!(r["action"], "fs.read");
        assert_eq!(r["params"], json!({"path": "/tmp/a"}));
        for (name, args) in [
            ("machine_read", json!({"path": "/tmp/a"})),
            ("machine_read", json!({"machine": "mac"})),
            ("machine_read", json!({"machine": "mac", "path": "/tmp", "op": "glob"})),
            ("machine_read", json!({"machine": "mac", "path": "/tmp", "op": "exec"})),
            ("machine_edit", json!({"machine": "mac", "path": "/tmp/a"})),
            (
                "machine_edit",
                json!({"machine": "mac", "path": "/tmp/a", "text": "x", "patch": "y"}),
            ),
            ("machine_edit", json!({"machine": "mac", "text": "x"})),
            ("machine_exec", json!({"machine": "mac"})),
            ("machine_exec", json!({"machine": "mac", "command": "ls", "argv": ["ls"]})),
        ] {
            assert!(request(name, &args).is_err(), "{name} {args}");
        }
    }

    #[test]
    fn machine_tools_show_a_file_and_a_command_as_text() {
        assert_eq!(text("fs.read", &json!({"text": "hi", "sha256": "abc"})), "hi\n[sha256 abc]");
        let out = text(
            "exec",
            &json!({"exit": 1, "stdout": "a\n", "stderr": "b\n", "truncated": false, "timed_out": false}),
        );
        assert_eq!(out, "exit 1\n--- stdout\na\n--- stderr\nb");
        assert!(text("exec", &json!({"exit": null, "timed_out": true})).starts_with("timed out"));
    }
}
