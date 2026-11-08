//! Code mode (Cloudflare's "Code Mode", Anthropic's "code execution with
//! MCP"): the Chief does not load every tool schema into its context. It
//! asks for the TypeScript declarations of the tools it needs (`describe`),
//! then writes a short script against them (`run`):
//!
//! ```ts
//! const page = await mcp.deepwiki.read_wiki_structure({ repoName: "facebook/react" });
//! console.log(page.slice(0, 400));
//! ```
//!
//! The script runs in a separate process with no network, no files and no
//! environment (Deno with no permissions; else Node's permission model; else
//! Bun, which has none). Its only way out is the `mcp` object: each call goes
//! as one line on its stdout to the hub, which makes the real MCP call with
//! the server's secrets and writes the answer back on its stdin. The script
//! never sees a token, and big intermediate results stay in the script.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// A call from a script: server, tool, arguments -> the value or an error.
pub type CallFn = Arc<dyn Fn(&str, &str, Value) -> Result<Value, String> + Send + Sync>;

/// The most a run prints back to the Chief.
pub const OUTPUT_MAX_CHARS: usize = 20_000;
/// The most MCP calls one script may make.
pub const CALLS_MAX: usize = 500;

const MARK: char = '\u{1e}';

/// A JavaScript runtime the hub runs scripts in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Runtime {
    /// `deno`, `node` or `bun`.
    pub kind: String,
    pub program: PathBuf,
}

impl Runtime {
    /// Whether the script runs without network, files and environment.
    pub fn sandboxed(&self) -> bool {
        self.kind == "deno"
    }
}

/// The runtime to use: `CMUX_MCP_CODE_RUNTIME` (a path or a kind), else
/// Deno, Node, Bun on PATH or in their usual install folders.
pub fn find_runtime(env: &dyn Fn(&str) -> Option<String>) -> Option<Runtime> {
    let home = env("HOME").unwrap_or_default();
    let mut dirs: Vec<PathBuf> = env("PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .collect();
    for extra in [".deno/bin", ".bun/bin", ".local/bin", ".volta/bin"] {
        dirs.push(Path::new(&home).join(extra));
    }
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map(PathBuf::from));
    let find = |kind: &str| -> Option<Runtime> {
        dirs.iter()
            .map(|d| d.join(kind))
            .find(|p| p.is_file())
            .map(|program| Runtime {
                kind: kind.to_owned(),
                program,
            })
    };
    if let Some(want) = env("CMUX_MCP_CODE_RUNTIME").filter(|w| !w.is_empty()) {
        let path = PathBuf::from(&want);
        if path.is_file() {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("node");
            let kind = ["deno", "bun"]
                .into_iter()
                .find(|k| name.starts_with(k))
                .unwrap_or("node");
            return Some(Runtime {
                kind: kind.to_owned(),
                program: path,
            });
        }
        return find(&want);
    }
    find("deno")
        .or_else(|| find("node"))
        .or_else(|| find("bun"))
}

// ---- declarations ----

/// `name` as a JS property: itself when it is an identifier, else quoted.
pub fn prop(name: &str) -> String {
    let ok = name.chars().enumerate().all(|(i, c)| {
        c == '_' || c == '$' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit())
    }) && !name.is_empty();
    if ok {
        name.to_owned()
    } else {
        format!("{:?}", name)
    }
}

/// The TypeScript type of a JSON Schema (the common keywords; else `unknown`).
pub fn ts_type(schema: &Value, depth: usize) -> String {
    if depth > 6 {
        return "unknown".into();
    }
    if let Some(values) = schema["enum"].as_array() {
        return values
            .iter()
            .map(|v| v.to_string())
            .collect::<Vec<_>>()
            .join(" | ");
    }
    if let Some(c) = schema.get("const") {
        return c.to_string();
    }
    for key in ["anyOf", "oneOf"] {
        if let Some(options) = schema[key].as_array() {
            let mut parts: Vec<String> = options.iter().map(|o| ts_type(o, depth + 1)).collect();
            parts.dedup();
            return parts.join(" | ");
        }
    }
    let one = |t: &str| -> String {
        match t {
            "string" => "string".into(),
            "number" | "integer" => "number".into(),
            "boolean" => "boolean".into(),
            "null" => "null".into(),
            "array" => {
                let item = ts_type(&schema["items"], depth + 1);
                if item.contains(' ') {
                    format!("Array<{item}>")
                } else {
                    format!("{item}[]")
                }
            }
            "object" => object_type(schema, depth),
            _ => "unknown".into(),
        }
    };
    match &schema["type"] {
        Value::String(t) => one(t),
        Value::Array(ts) => ts
            .iter()
            .filter_map(Value::as_str)
            .map(one)
            .collect::<Vec<_>>()
            .join(" | "),
        _ if schema.get("properties").is_some() => object_type(schema, depth),
        _ => "unknown".into(),
    }
}

fn object_type(schema: &Value, depth: usize) -> String {
    let Some(props) = schema["properties"].as_object() else {
        return "Record<string, unknown>".into();
    };
    if props.is_empty() {
        return "{}".into();
    }
    let required: Vec<&str> = schema["required"]
        .as_array()
        .map(|r| r.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let pad = "  ".repeat(depth + 2);
    let mut out = String::from("{\n");
    for (name, sub) in props {
        if let Some(d) = sub["description"].as_str() {
            out.push_str(&format!("{pad}/** {} */\n", one_line(d, 200)));
        }
        out.push_str(&format!(
            "{pad}{}{}: {};\n",
            prop(name),
            if required.contains(&name.as_str()) {
                ""
            } else {
                "?"
            },
            ts_type(sub, depth + 1)
        ));
    }
    out.push_str(&"  ".repeat(depth + 1));
    out.push('}');
    out
}

/// `text` on one line, at most `max` characters, no comment terminators.
pub fn one_line(text: &str, max: usize) -> String {
    let flat: String = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("*/", "* /");
    if flat.chars().count() > max {
        format!("{}...", flat.chars().take(max).collect::<String>())
    } else {
        flat
    }
}

/// The declarations of `tools` of `server` (only `only`, when given).
pub fn declarations(
    server: &str,
    tools: &[Value],
    flagged: &[String],
    only: Option<&str>,
) -> String {
    let mut out = format!("declare namespace mcp.{} {{\n", prop(server));
    for tool in tools {
        let name = tool["name"].as_str().unwrap_or("");
        if only.is_some_and(|o| o != name) {
            continue;
        }
        let description = if flagged.iter().any(|f| f == name) {
            "[description withheld: it looked like instructions to the model]".to_owned()
        } else {
            one_line(tool["description"].as_str().unwrap_or(""), 600)
        };
        let mut notes = Vec::new();
        if tool["annotations"]["readOnlyHint"] == json!(true) {
            notes.push("read-only");
        }
        if tool["annotations"]["destructiveHint"] == json!(true) {
            notes.push("destructive");
        }
        match tool["execution"]["taskSupport"].as_str() {
            Some("required") => notes.push("runs as a task"),
            Some("optional") => notes.push("can run as a task"),
            _ => {}
        }
        out.push_str(&format!(
            "  /** {description}{} */\n  function {}(args{}: {}): Promise<{}>;\n",
            if notes.is_empty() {
                String::new()
            } else {
                format!(" ({})", notes.join(", "))
            },
            prop(name),
            if tool["inputSchema"]["required"]
                .as_array()
                .is_some_and(|r| !r.is_empty())
            {
                ""
            } else {
                "?"
            },
            ts_type(&tool["inputSchema"], 0),
            tool.get("outputSchema")
                .map(|s| ts_type(s, 0))
                .unwrap_or_else(|| "any".into()),
        ));
    }
    out.push_str("}\n");
    out
}

/// What a script gets back from a `tools/call` result: `structuredContent`
/// when there is one, else the text (parsed when it is JSON); an error result
/// is thrown.
pub fn script_value(result: &Value) -> Result<Value, String> {
    let text = result_text(result);
    if result["isError"] == json!(true) {
        return Err(if text.is_empty() {
            "the tool failed".into()
        } else {
            text
        });
    }
    if let Some(s) = result.get("structuredContent").filter(|s| !s.is_null()) {
        return Ok(s.clone());
    }
    Ok(serde_json::from_str::<Value>(text.trim())
        .ok()
        .filter(|v| v.is_object() || v.is_array())
        .unwrap_or(Value::String(text)))
}

/// A tool result's content as text (non-text parts named).
pub fn result_text(result: &Value) -> String {
    let parts: Vec<String> = result["content"]
        .as_array()
        .map(|c| {
            c.iter()
                .map(|p| match p["type"].as_str() {
                    Some("text") => p["text"].as_str().unwrap_or("").to_owned(),
                    Some("resource") => p["resource"]["text"]
                        .as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| {
                            format!("[resource {}]", p["resource"]["uri"].as_str().unwrap_or(""))
                        }),
                    Some("resource_link") => format!("[link {}]", p["uri"].as_str().unwrap_or("")),
                    Some(t) => format!("[{t} {}]", p["mimeType"].as_str().unwrap_or("")),
                    None => String::new(),
                })
                .collect()
        })
        .unwrap_or_default();
    if parts.is_empty()
        && let Some(s) = result.get("structuredContent").filter(|s| !s.is_null())
    {
        return s.to_string();
    }
    parts.join("\n")
}

// ---- the runner ----

const PRELUDE: &str = r#"const __enc = new TextEncoder();
const __isDeno = typeof Deno !== "undefined";
function __w(o) {
  const s = "\u001e" + JSON.stringify(o) + "\n";
  if (__isDeno) { const b = __enc.encode(s); let n = 0; while (n < b.length) n += Deno.stdout.writeSync(b.subarray(n)); }
  else process.stdout.write(s);
}
const __pending = new Map(); let __next = 1;
function __call(server, tool, args) {
  const id = __next++;
  __w({ k: "call", id, server: String(server), tool: String(tool), args: args ?? {} });
  return new Promise((res, rej) => __pending.set(id, { res, rej }));
}
function __reply(line) {
  if (!line.trim()) return;
  const m = JSON.parse(line); const p = __pending.get(m.id); if (!p) return;
  __pending.delete(m.id); m.ok ? p.res(m.value) : p.rej(new Error(m.error));
}
if (__isDeno) {
  (async () => { const d = new TextDecoder(); let buf = "";
    for await (const c of Deno.stdin.readable) { buf += d.decode(c, { stream: true }); let i;
      while ((i = buf.indexOf("\n")) >= 0) { __reply(buf.slice(0, i)); buf = buf.slice(i + 1); } } })();
} else {
  let buf = ""; process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => { buf += c; let i;
    while ((i = buf.indexOf("\n")) >= 0) { __reply(buf.slice(0, i)); buf = buf.slice(i + 1); } });
}
const mcp = new Proxy({}, { get(_, server) {
  if (server === "then") return undefined;
  if (server === "$call") return __call;
  if (server === "$servers") return () => __call("$hub", "servers", {});
  if (server === "$search") return (query) => __call("$hub", "search", { query });
  if (server === "$describe") return (s, tool) => __call("$hub", "describe", { server: s, tool });
  return new Proxy({}, { get(_, tool) {
    if (tool === "then") return undefined;
    return (args) => __call(server, tool, args);
  } });
} });
globalThis.mcp = mcp;
const __fmt = (a) => { if (typeof a === "string") return a; try { return JSON.stringify(a, null, 2); } catch { return String(a); } };
console.log = (...a) => __w({ k: "log", text: a.map(__fmt).join(" ") });
console.info = console.log; console.warn = console.log; console.error = console.log; console.debug = console.log;
(async () => {
"#;

const POSTLUDE: &str = r#"
})().then((v) => __w({ k: "done", value: v === undefined ? null : v }),
  (e) => __w({ k: "error", message: String((e && e.stack) || e) }));
"#;

/// The script file the runtime runs.
pub fn script(code: &str) -> String {
    format!("{PRELUDE}{code}{POSTLUDE}")
}

/// The command that runs `file` in `runtime`, sandboxed as far as it allows.
pub fn command(runtime: &Runtime, file: &Path) -> Command {
    let mut cmd = Command::new(&runtime.program);
    match runtime.kind.as_str() {
        "deno" => {
            cmd.args([
                "run",
                "--quiet",
                "--no-prompt",
                "--no-config",
                "--no-lock",
                "--no-remote",
                "--no-npm",
            ])
            .arg("--v8-flags=--max-old-space-size=512")
            .arg(file);
        }
        "node" => {
            cmd.arg("--permission")
                .arg(format!("--allow-fs-read={}", file.display()))
                .arg("--max-old-space-size=512")
                .arg("--no-warnings")
                .arg(file);
        }
        _ => {
            cmd.arg("run").arg(file);
        }
    }
    cmd
}

/// Runs `code` with the `mcp` object bound to `call`; answers what it
/// printed and returned, or why it failed.
pub fn run(
    runtime: &Runtime,
    code: &str,
    dir: &Path,
    timeout: Duration,
    call: CallFn,
) -> Result<String, String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let file = dir.join(format!("run-{}-{}.ts", std::process::id(), super::now_ms()));
    std::fs::write(&file, script(code)).map_err(|e| e.to_string())?;
    let result = run_file(runtime, &file, dir, timeout, call);
    let _ = std::fs::remove_file(&file);
    result
}

fn run_file(
    runtime: &Runtime,
    file: &Path,
    dir: &Path,
    timeout: Duration,
    call: CallFn,
) -> Result<String, String> {
    let mut cmd = command(runtime, file);
    cmd.env_clear()
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    for key in ["PATH", "HOME", "TMPDIR", "DENO_DIR", "LANG"] {
        if let Ok(v) = std::env::var(key) {
            cmd.env(key, v);
        }
    }
    cmd.env("NO_COLOR", "1");
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("could not start {}: {e}", runtime.program.display()))?;
    let pid = child.id() as i32;
    let stdin = Arc::new(Mutex::new(Some(child.stdin.take().expect("piped"))));
    let stdout = child.stdout.take().expect("piped");
    let mut stderr = child.stderr.take().expect("piped");
    let err_text = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut s);
        s
    });
    let (tx, rx) = channel::<Result<Value, String>>();
    let logs = Arc::new(Mutex::new(String::new()));
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    {
        let (stdin, logs, calls) = (stdin.clone(), logs.clone(), calls.clone());
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let Some(body) = line.strip_prefix(MARK) else {
                    push_log(&logs, &line);
                    continue;
                };
                let Ok(msg) = serde_json::from_str::<Value>(body) else {
                    continue;
                };
                let kind = msg["k"].as_str().unwrap_or("").to_owned();
                match kind.as_str() {
                    "log" => push_log(&logs, msg["text"].as_str().unwrap_or("")),
                    "done" => {
                        let _ = tx.send(Ok(msg["value"].clone()));
                        return;
                    }
                    "error" => {
                        let _ = tx.send(Err(msg["message"].as_str().unwrap_or("error").to_owned()));
                        return;
                    }
                    "call" => {
                        let n = calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        let (stdin, call) = (stdin.clone(), call.clone());
                        std::thread::spawn(move || {
                            let id = msg["id"].clone();
                            let answer = if n >= CALLS_MAX {
                                Err(format!("a script may make at most {CALLS_MAX} MCP calls"))
                            } else {
                                call(
                                    msg["server"].as_str().unwrap_or(""),
                                    msg["tool"].as_str().unwrap_or(""),
                                    msg["args"].clone(),
                                )
                            };
                            let reply = match answer {
                                Ok(value) => json!({"id": id, "ok": true, "value": value}),
                                Err(error) => json!({"id": id, "ok": false, "error": error}),
                            };
                            if let Some(w) = stdin.lock().unwrap().as_mut() {
                                let _ = writeln!(w, "{reply}");
                                let _ = w.flush();
                            }
                        });
                    }
                    _ => {}
                }
            }
            let _ = tx.send(Err("the script ended before it finished".into()));
        });
    }
    let started = Instant::now();
    let outcome = match rx.recv_timeout(timeout) {
        Ok(r) => r,
        Err(RecvTimeoutError::Timeout) => Err(format!(
            "the script ran past {}s and was stopped",
            timeout.as_secs()
        )),
        Err(_) => Err("the script ended before it finished".into()),
    };
    // End the script: close its input, then end its process group.
    stdin.lock().unwrap().take();
    std::thread::sleep(Duration::from_millis(50));
    // SAFETY: kill(2) takes plain integers and touches no Rust memory; the
    // group is the one this function started (process_group(0)).
    unsafe {
        libc::kill(-pid, libc::SIGKILL);
    }
    let _ = child.wait();
    let stderr_text = err_text.join().unwrap_or_default();
    let logs = logs.lock().unwrap().clone();
    let mut out = String::new();
    if !logs.is_empty() {
        out.push_str(&logs);
        if !out.ends_with('\n') {
            out.push('\n');
        }
    }
    let n = calls.load(std::sync::atomic::Ordering::SeqCst);
    match outcome {
        Ok(value) => {
            if !value.is_null() {
                let shown = match &value {
                    Value::String(s) => s.clone(),
                    v => serde_json::to_string_pretty(v).unwrap_or_default(),
                };
                out.push_str("Returned: ");
                out.push_str(&shown);
                out.push('\n');
            }
            out.push_str(&format!(
                "(ran in {} in {:.1}s, {n} MCP call(s){})",
                runtime.kind,
                started.elapsed().as_secs_f32(),
                if runtime.sandboxed() {
                    ", sandboxed"
                } else {
                    ""
                }
            ));
            Ok(cap(&out))
        }
        Err(e) => {
            out.push_str(&format!("The script failed: {e}"));
            let tail = stderr_text.trim();
            if !tail.is_empty() {
                out.push_str(&format!("\n{}", one_line_tail(tail)));
            }
            Err(cap(&out))
        }
    }
}

fn one_line_tail(text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(12)..].join("\n")
}

fn push_log(logs: &Mutex<String>, line: &str) {
    let mut l = logs.lock().unwrap();
    if l.len() < OUTPUT_MAX_CHARS * 2 {
        l.push_str(line);
        l.push('\n');
    }
}

/// `text` cut to [`OUTPUT_MAX_CHARS`], saying so.
pub fn cap(text: &str) -> String {
    if text.chars().count() <= OUTPUT_MAX_CHARS {
        return text.to_owned();
    }
    let kept: String = text.chars().take(OUTPUT_MAX_CHARS).collect();
    format!(
        "{kept}\n[output cut at {OUTPUT_MAX_CHARS} characters: print less, or slice in the script]"
    )
}
