//! The tool calls of an adopted chat's past turns (hq#2569 item 3), read from the harness's own
//! transcript (`adopt_replay.rs`) as the ACP tool calls a live turn sends: a Codex command, file
//! change, MCP call or web search, and a Claude Code `tool_use` with its `tool_result`. Each is
//! the fields of its `tool_call` and of the `tool_call_update` that settles it, so the pane draws
//! a reopened turn's work as it drew it live ("Ran 3 commands", "Edited 2 files +4 -1").
//!
//! The transcript is the record: no file is read, so an edit's before and after text are its
//! hunks' lines (context and removed, context and added), with each file's +/- counts.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// One past tool call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PastTool {
    pub id: String,
    /// The `tool_call` fields: `kind`, `title`, `rawInput`, `locations`.
    pub call: Value,
    /// The `tool_call_update` fields that settle it: `status`, `content`, `rawOutput`.
    pub done: Value,
    /// When it started and ended (ms since the epoch), when recorded.
    pub started_at: Option<u64>,
    pub ended_at: Option<u64>,
    /// An edit's proposed diffs, kept out of `done` until a result that did not fail confirms
    /// them: a Claude Code edit cut off before its result, or refused, changed nothing.
    pub proposed: Option<Value>,
}

/// A tool call's result, found after the call (Claude Code's `tool_result`, Codex's older
/// `patch_apply_end`): its `status`, and `content` unless the call already carries its own (an
/// edit's diff) and did not fail.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolResult {
    pub id: String,
    pub done: Value,
    /// Claude Code's structured result beside it (the transcript line's `toolUseResult`): for a
    /// Write, whether it created its file and the file's text before it (`settle_write`).
    pub structured: Option<Value>,
}

impl PastTool {
    /// Settles the call with `result` at `at`.
    pub fn settle(&mut self, result: &ToolResult, at: Option<u64>) {
        let failed = result.done["status"] == "failed";
        if let (Some(proposed), false) = (self.proposed.take(), failed) {
            // A Write's diff is a fragment until its result says it created the file or holds
            // the text it replaced; otherwise Undo would read the file as one the turn created.
            let text = result.done.pointer("/content/0/content/text").and_then(Value::as_str);
            self.done.set(
                "content",
                crate::claude_stdio::settle_write(
                    proposed,
                    text.unwrap_or_default(),
                    result.structured.as_ref(),
                ),
            );
        }
        if let (Some(done), Some(update)) = (self.done.as_object_mut(), result.done.as_object()) {
            for (key, value) in update {
                if key != "content" || failed || !done.contains_key("content") {
                    done.insert(key.clone(), value.clone());
                }
            }
        }
        // An edit that failed changed nothing: its files keep no +/- counts.
        if failed
            && let Some(changes) =
                self.call.pointer_mut("/rawInput/changes").and_then(Value::as_array_mut)
        {
            for change in changes.iter_mut().filter_map(Value::as_object_mut) {
                change.remove("additions");
                change.remove("deletions");
            }
        }
        self.ended_at = at.or(self.ended_at);
    }
}

/// The most of a call's output kept, and the most of one side of an edit's text.
const MAX_OUTPUT: usize = 8_000;
const MAX_DIFF_TEXT: usize = 64_000;

fn s<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

/// `text` cut to at most `max` bytes, on a character boundary.
fn capped(text: &str, max: usize) -> String {
    let mut cut = text.len().min(max);
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    text[..cut].to_owned()
}

fn text_content(text: &str) -> Value {
    json!({"type": "content", "content": {"type": "text", "text": capped(text, MAX_OUTPUT)}})
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').find(|part| !part.is_empty()).unwrap_or(path)
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").chars().take(160).collect()
}

/// A Codex duration (`{secs, nanos}`) in ms.
fn duration_ms(value: Option<&Value>) -> Option<u64> {
    let value = value?;
    let secs = value.get("secs").and_then(Value::as_u64)?;
    let nanos = value.get("nanos").and_then(Value::as_u64).unwrap_or(0);
    Some(secs.saturating_mul(1000).saturating_add(nanos / 1_000_000))
}

/// A Codex item status as an ACP one.
fn status(item: &Value) -> &'static str {
    match s(item, "status") {
        Some("failed" | "declined" | "interrupted") => "failed",
        _ => "completed",
    }
}

/// The script a shell wrapper runs (`["/bin/zsh", "-lc", "git status"]` is `git status`), else
/// the command line as it reads.
fn shell_command(command: &Value) -> Option<String> {
    if let Some(line) = command.as_str() {
        return Some(line.to_owned());
    }
    let argv: Vec<&str> = command.as_array()?.iter().filter_map(Value::as_str).collect();
    if let [program, flag, script] = argv.as_slice() {
        let shell = matches!(file_name(program), "sh" | "bash" | "zsh" | "dash" | "fish");
        if shell && matches!(*flag, "-c" | "-lc") {
            return Some((*script).to_owned());
        }
    }
    (!argv.is_empty()).then(|| argv.join(" "))
}

/// A Codex command (`CommandExecution`, or an older `exec_command_end`): one read is a read,
/// one search or listing a search, anything else a command, as cmux-codex-acp draws them live.
fn codex_command(id: &str, item: &Value, at: Option<u64>) -> Option<PastTool> {
    let script = shell_command(item.get("command")?)?;
    let cwd = s(item, "cwd").map(|cwd| cwd.strip_prefix("file://").unwrap_or(cwd));
    let actions: Vec<&Value> =
        item.get("parsed_cmd").and_then(Value::as_array).into_iter().flatten().collect();
    let path = actions.first().and_then(|a| s(a, "path")).map(str::to_owned);
    let (kind, title) = match actions.as_slice() {
        [a] if s(a, "type") == Some("read") => {
            ("read", format!("Read {}", s(a, "name").or(path.as_deref()).unwrap_or(&script)))
        }
        [a] if s(a, "type") == Some("search") => {
            ("search", s(a, "query").map_or_else(|| first_line(&script), |q| format!("Search {q}")))
        }
        [a] if s(a, "type") == Some("list_files") => {
            ("search", format!("List {}", path.as_deref().unwrap_or(".")))
        }
        _ => ("execute", first_line(&script)),
    };
    let mut call =
        json!({"kind": kind, "title": title, "rawInput": {"command": script, "cwd": cwd}});
    if kind != "execute"
        && let Some(path) = path
    {
        call.set("locations", json!([{"path": path}]));
    }
    let output = ["aggregated_output", "formatted_output", "stdout"]
        .iter()
        .find_map(|key| s(item, key))
        .unwrap_or("");
    let exit_code = item.get("exit_code").and_then(Value::as_i64);
    let took = duration_ms(item.get("duration"));
    let failed = status(item) == "failed" || exit_code.is_some_and(|code| code != 0);
    let mut done = json!({
        "status": if failed { "failed" } else { "completed" },
        "rawOutput": {"exit_code": exit_code, "duration_ms": took},
    });
    if !output.is_empty() {
        done.set("content", json!([text_content(output)]));
    }
    Some(PastTool {
        id: id.to_owned(),
        call,
        done,
        started_at: at.map(|end| end.saturating_sub(took.unwrap_or(0))),
        ended_at: at,
        proposed: None,
    })
}

/// One file of a change: `add`, `update` or `delete`, its text (an added or deleted file's
/// content, an update's unified diff) and where a move put it.
struct Change {
    path: String,
    kind: String,
    text: String,
    move_path: Option<String>,
}

/// A change's files: current Codex's `{path: {type, unified_diff|content, move_path}}`, older
/// Codex's `{path: {"update": {unified_diff, move_path}}}`, or app-server's `[{path, kind, diff}]`.
fn changes(value: &Value) -> Vec<Change> {
    let text = |v: &Value| {
        ["unified_diff", "content", "diff"].iter().find_map(|k| s(v, k)).unwrap_or("").to_owned()
    };
    let move_path = |v: &Value| s(v, "move_path").map(str::to_owned);
    if let Some(list) = value.as_array() {
        return list
            .iter()
            .filter_map(|c| {
                let kind = c.pointer("/kind/type").and_then(Value::as_str).unwrap_or("update");
                Some(Change {
                    path: s(c, "path")?.to_owned(),
                    kind: kind.to_owned(),
                    text: text(c),
                    move_path: c
                        .pointer("/kind/move_path")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                })
            })
            .collect();
    }
    let Some(map) = value.as_object() else { return Vec::new() };
    map.iter()
        .map(|(path, c)| {
            let (kind, body) = match s(c, "type") {
                Some(kind) => (kind.to_owned(), c),
                None => match c.as_object().and_then(|o| o.iter().next()) {
                    Some((kind, body)) => (kind.clone(), body),
                    None => ("update".to_owned(), c),
                },
            };
            Change { path: path.clone(), kind, text: text(body), move_path: move_path(body) }
        })
        .collect()
}

/// One hunk of a unified diff: its old start line, and the lines it expects and leaves.
struct Hunk {
    old_start: u64,
    old: Vec<String>,
    new: Vec<String>,
    additions: u64,
    deletions: u64,
}

fn hunks(diff: &str) -> Vec<Hunk> {
    let mut out: Vec<Hunk> = Vec::new();
    for line in diff.strip_suffix('\n').unwrap_or(diff).split('\n') {
        let header = if line == "@@" { Some("") } else { line.strip_prefix("@@ ") };
        if let Some(rest) = header {
            let old_start = rest
                .split(' ')
                .find_map(|w| w.strip_prefix('-'))
                .and_then(|range| range.split(',').next()?.parse().ok())
                .unwrap_or(1);
            out.push(Hunk {
                old_start,
                old: Vec::new(),
                new: Vec::new(),
                additions: 0,
                deletions: 0,
            });
            continue;
        }
        // File headers ("--- a", "+++ b") come before the first hunk only.
        let Some(hunk) = out.last_mut() else { continue };
        match line.chars().next() {
            Some('-') => {
                hunk.old.push(line[1..].to_owned());
                hunk.deletions += 1;
            }
            Some('+') => {
                hunk.new.push(line[1..].to_owned());
                hunk.additions += 1;
            }
            Some(' ') => {
                hunk.old.push(line[1..].to_owned());
                hunk.new.push(line[1..].to_owned());
            }
            // A blank context line whose leading space was trimmed.
            None => {
                hunk.old.push(String::new());
                hunk.new.push(String::new());
            }
            // "\ No newline at end of file".
            Some(_) => {}
        }
    }
    out
}

fn joined(lines: &[String]) -> String {
    let mut text = lines.join("\n");
    if !lines.is_empty() {
        text.push('\n');
    }
    text
}

/// A Codex file change (`FileChange`, or an older patch event): one edit over its files, each
/// hunk an ACP `diff` of its lines, the call's input naming each file with its +/- counts (the
/// edited-files card's numbers). A hunk too big to draw is shown as the diff's text. A hunk is
/// part of its file, not the whole of it, so its diff says so (`_meta.acpmux.fragment`): the
/// card's Undo needs whole-file texts. A change that failed (declined, or a patch that did not
/// apply) changed nothing: it keeps its files and its error, but no diffs or counts.
fn codex_file_change(
    id: &str,
    value: &Value,
    status: &str,
    error: Option<&str>,
    at: Option<u64>,
) -> Option<PastTool> {
    let files = changes(value);
    if files.is_empty() {
        return None;
    }
    let failed = status == "failed";
    let mut content = Vec::new();
    let mut locations = Vec::new();
    let mut summary = Vec::new();
    for change in &files {
        let target = change.move_path.as_deref().unwrap_or(&change.path);
        let (additions, deletions) = match change.kind.as_str() {
            "add" => {
                content.push(json!({"type": "diff", "path": target, "newText": change.text}));
                locations.push(json!({"path": target}));
                (change.text.lines().count() as u64, 0)
            }
            "delete" => {
                content.push(
                    json!({"type": "diff", "path": target, "oldText": change.text, "newText": ""}),
                );
                locations.push(json!({"path": target}));
                (0, change.text.lines().count() as u64)
            }
            _ => {
                let parts = hunks(&change.text);
                if parts.is_empty() && !change.text.is_empty() {
                    content.push(text_content(&format!("{target}\n{}", change.text)));
                }
                for hunk in &parts {
                    content.push(json!({"type": "diff", "path": target, "oldText": joined(&hunk.old), "newText": joined(&hunk.new), "_meta": {"acpmux": {"fragment": true}}}));
                }
                // A location's line numbers its file's diffs: only one hunk starts there.
                locations.push(match parts.as_slice() {
                    [one] => json!({"path": target, "line": one.old_start}),
                    _ => json!({"path": target}),
                });
                parts.iter().fold((0, 0), |(a, d), h| (a + h.additions, d + h.deletions))
            }
        };
        let mut entry = json!({"path": target, "type": change.kind});
        if !failed {
            entry.set("additions", json!(additions));
            entry.set("deletions", json!(deletions));
        }
        if change.move_path.is_some() {
            entry.set("from", json!(change.path));
        }
        summary.push(entry);
    }
    // An edit too big to draw shows its files' diffs as text.
    let mut content = Value::Array(content);
    if failed {
        content = error.map(text_content).into_iter().collect();
    } else if oversize(&content) {
        content = files
            .iter()
            .map(|c| {
                text_content(&format!("{}\n{}", c.move_path.as_deref().unwrap_or(&c.path), c.text))
            })
            .collect();
    }
    let title = match files.as_slice() {
        [one] => {
            let verb = match one.kind.as_str() {
                "add" => "Write",
                "delete" => "Delete",
                _ => "Edit",
            };
            format!("{verb} {}", file_name(one.move_path.as_deref().unwrap_or(&one.path)))
        }
        many => format!("Edit {} files", many.len()),
    };
    Some(PastTool {
        id: id.to_owned(),
        call: json!({"kind": "edit", "title": title, "locations": locations, "rawInput": {"changes": summary}}),
        done: json!({"status": status, "content": content}),
        started_at: at,
        ended_at: at,
        proposed: None,
    })
}

/// MCP or tool result blocks as ACP content: their text.
fn result_text(blocks: Option<&Value>) -> Vec<Value> {
    match blocks {
        Some(Value::String(text)) if !text.is_empty() => vec![text_content(text)],
        Some(Value::Array(blocks)) => {
            let text: Vec<&str> = blocks.iter().filter_map(|b| s(b, "text")).collect();
            if text.is_empty() { Vec::new() } else { vec![text_content(&text.join("\n"))] }
        }
        _ => Vec::new(),
    }
}

/// A Codex MCP call.
fn codex_mcp(id: &str, item: &Value, at: Option<u64>) -> PastTool {
    let server = s(item, "server").unwrap_or("mcp");
    let tool = s(item, "tool").unwrap_or("tool");
    let took = duration_ms(item.get("duration"));
    let failed = status(item) == "failed"
        || item.pointer("/result/isError").and_then(Value::as_bool) == Some(true);
    PastTool {
        id: id.to_owned(),
        call: json!({"kind": "other", "title": format!("{server}: {tool}"), "rawInput": item.get("arguments")}),
        done: json!({
            "status": if failed { "failed" } else { "completed" },
            "content": result_text(item.pointer("/result/content")),
        }),
        started_at: at.map(|end| end.saturating_sub(took.unwrap_or(0))),
        ended_at: at,
        proposed: None,
    }
}

/// What a Codex rollout record says a tool did, at `at`. `items`: the record is current Codex's
/// `item_completed` (`Some(true)`), or an older event (`Some(false)`); None when neither.
pub fn codex_tool(record: &Value, at: Option<u64>) -> Option<(Result<PastTool, ToolResult>, bool)> {
    if s(record, "type") != Some("event_msg") {
        return None;
    }
    let payload = record.get("payload")?;
    match s(payload, "type")? {
        "item_completed" => {
            let item = payload.get("item")?;
            let id = s(item, "id")?;
            let tool = match s(item, "type")? {
                "CommandExecution" => codex_command(id, item, at)?,
                "FileChange" => {
                    let error = s(item, "stderr").filter(|t| !t.is_empty());
                    codex_file_change(id, item.get("changes")?, status(item), error, at)?
                }
                "McpToolCall" => codex_mcp(id, item, at),
                "Extension" if s(item, "kind") == Some("web.search") => {
                    let query = s(item, "query").unwrap_or("");
                    PastTool {
                        id: id.to_owned(),
                        call: json!({"kind": "fetch", "title": if query.is_empty() { "Web search".to_owned() } else { format!("Search {query}") }, "rawInput": {"query": query}}),
                        done: json!({"status": status(item)}),
                        started_at: at,
                        ended_at: at,
                        proposed: None,
                    }
                }
                _ => return None,
            };
            Some((Ok(tool), true))
        }
        "exec_command_end" => {
            Some((Ok(codex_command(s(payload, "call_id")?, payload, at)?), false))
        }
        "patch_apply_begin" => {
            let id = s(payload, "call_id")?;
            Some((
                Ok(codex_file_change(id, payload.get("changes")?, "completed", None, at)?),
                false,
            ))
        }
        "patch_apply_end" => {
            let id = s(payload, "call_id")?;
            let state = if payload.get("success").and_then(Value::as_bool) == Some(false) {
                "failed"
            } else {
                "completed"
            };
            let error = s(payload, "stderr").filter(|t| state == "failed" && !t.is_empty());
            if let Some(tool) =
                payload.get("changes").and_then(|c| codex_file_change(id, c, state, error, at))
            {
                return Some((Ok(tool), false));
            }
            let mut done = json!({"status": state});
            if state == "failed" {
                // The begin event's diffs never applied: the error, or nothing, replaces them.
                done.set("content", error.map(text_content).into_iter().collect());
            }
            Some((Err(ToolResult { id: id.to_owned(), done, structured: None }), false))
        }
        "mcp_tool_call_end" => {
            let id = s(payload, "call_id")?;
            let invocation = payload.get("invocation").cloned().unwrap_or(Value::Null);
            let result = payload.get("result");
            let ok = result.and_then(|r| r.get("Ok"));
            let mut item = json!({
                "server": invocation.get("server"),
                "tool": invocation.get("tool"),
                "arguments": invocation.get("arguments"),
                "duration": payload.get("duration"),
                "status": if ok.is_some() { "completed" } else { "failed" },
            });
            if let Some(ok) = ok {
                item.set("result", ok.clone());
            }
            Some((Ok(codex_mcp(id, &item, at)), false))
        }
        _ => None,
    }
}

/// Claude Code's `tool_use` blocks in an assistant message, as the calls a live turn sends
/// (`claude_stdio::tool_call_fields`), not yet settled: a call whose result never came (a turn
/// cut off) stays failed and shows no diff. An edit's diffs settle it only with a result that
/// did not fail; one too big to draw is left out. The todo list is the turn's plan, not a call.
pub fn claude_tool_uses(content: &Value, at: Option<u64>) -> Vec<PastTool> {
    content
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| s(b, "type") == Some("tool_use"))
        .filter_map(|block| {
            let id = s(block, "id")?;
            let name = s(block, "name").filter(|name| *name != "TodoWrite")?;
            let input = block.get("input").cloned().unwrap_or(Value::Null);
            let mut call = crate::claude_stdio::tool_call_fields(name, &input);
            let diffs = call.as_object_mut().and_then(|c| c.remove("content"));
            Some(PastTool {
                id: id.to_owned(),
                call,
                done: json!({"status": "failed"}),
                started_at: at,
                ended_at: None,
                proposed: diffs.filter(|d| !oversize(d)),
            })
        })
        .collect()
}

/// Whether some diff in `content` has a side too big to draw.
fn oversize(content: &Value) -> bool {
    content.as_array().into_iter().flatten().any(|c| {
        ["oldText", "newText"].iter().any(|k| s(c, k).is_some_and(|t| t.len() > MAX_DIFF_TEXT))
    })
}

/// Claude Code's `tool_result` blocks in a user message; `structured` is the line's
/// `toolUseResult`, which `settle_write` checks against each Write's own path.
pub fn claude_tool_results(content: &Value, structured: Option<&Value>) -> Vec<ToolResult> {
    content
        .as_array()
        .into_iter()
        .flatten()
        .filter(|b| s(b, "type") == Some("tool_result"))
        .filter_map(|block| {
            let failed = block.get("is_error").and_then(Value::as_bool) == Some(true);
            // Its text, then the images it returned (a Read of a PNG), as a live turn sends them.
            // What is kept is bounded by the transcript tail adopt reads (`adopt_replay::MAX_BYTES`),
            // which already holds each image.
            let mut content = result_text(block.get("content"));
            content.extend(crate::claude_stdio::result_images(block.get("content")));
            Some(ToolResult {
                id: s(block, "tool_use_id")?.to_owned(),
                done: json!({
                    "status": if failed { "failed" } else { "completed" },
                    "content": content,
                }),
                structured: structured.cloned(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(id: &str) -> Value {
        json!([{"type": "tool_use", "id": id, "name": "Edit",
                "input": {"file_path": "/p/src/lib.rs", "old_string": "a", "new_string": "b"}}])
    }

    fn result(id: &str, is_error: bool) -> ToolResult {
        let block = json!([{"type": "tool_result", "tool_use_id": id, "content": "ok", "is_error": is_error}]);
        claude_tool_results(&block, None).remove(0)
    }

    /// A Claude Code edit shows its diff only once a result that did not fail confirms it: one
    /// cut off before its result, or refused, changed nothing and counts no edited file.
    #[test]
    fn a_claude_edit_shows_its_diff_only_when_its_result_confirms_it() {
        let [cut_off] = claude_tool_uses(&edit("t1"), Some(1)).try_into().unwrap();
        assert_eq!(cut_off.done, json!({"status": "failed"}));

        let [mut refused] = claude_tool_uses(&edit("t2"), Some(1)).try_into().unwrap();
        refused.settle(&result("t2", true), Some(2));
        assert_eq!(refused.done["status"], "failed");
        assert_eq!(refused.done["content"], json!([text_content("ok")]));

        let [mut applied] = claude_tool_uses(&edit("t3"), Some(1)).try_into().unwrap();
        applied.settle(&result("t3", false), Some(2));
        assert_eq!(applied.done["status"], "completed");
        assert_eq!(applied.done["content"][0]["type"], "diff", "{}", applied.done);
        assert_eq!(applied.done["content"][0]["newText"], "b");
    }

    /// An adopted Read of an image keeps the image its result returned, so a reopened chat on
    /// another machine draws it instead of "Image unavailable".
    #[test]
    fn an_adopted_claude_read_keeps_the_image_its_result_returned() {
        let read = json!([{"type": "tool_use", "id": "r1", "name": "Read",
                           "input": {"file_path": "/tmp/shot.png"}}]);
        let [mut tool] = claude_tool_uses(&read, Some(1)).try_into().unwrap();
        let block = json!([{"type": "tool_result", "tool_use_id": "r1", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0K"}}]}]);
        let [result] = claude_tool_results(&block, None).try_into().unwrap();
        tool.settle(&result, Some(2));
        assert_eq!(tool.done["status"], "completed");
        assert_eq!(
            tool.done["content"],
            json!([{"type": "content", "content": {"type": "image", "mimeType": "image/png", "data": "iVBORw0K"}}])
        );
    }

    fn write(id: &str) -> Value {
        json!([{"type": "tool_use", "id": id, "name": "Write",
                "input": {"file_path": "/p/notes.md", "content": "new\n"}}])
    }

    /// An adopted Write as the transcript line records it: the tool_result and, beside the
    /// message, `toolUseResult`.
    fn write_settled(id: &str, text: &str, structured: Option<Value>) -> Value {
        let [mut tool] = claude_tool_uses(&write(id), Some(1)).try_into().unwrap();
        let block = json!([{"type": "tool_result", "tool_use_id": id, "content": text}]);
        let [result] = claude_tool_results(&block, structured.as_ref()).try_into().unwrap();
        tool.settle(&result, Some(2));
        assert_eq!(tool.done["status"], "completed");
        tool.done["content"][0].clone()
    }

    /// An adopted Claude Write reads as a new file (which Undo may trash) only when its result
    /// says it created the file; over a file that was there it carries the old text, or stays a
    /// fragment, so Undo never trashes an overwritten file.
    #[test]
    fn an_adopted_claude_write_is_new_only_when_its_result_says_it_created_the_file() {
        let fragment = |diff: &Value| diff.pointer("/_meta/acpmux/fragment") == Some(&json!(true));

        let created = json!({"type": "create", "filePath": "/p/notes.md", "originalFile": null});
        let diff = write_settled("w1", "File created successfully at: /p/notes.md", Some(created));
        assert_eq!(diff["oldText"], Value::Null);
        assert!(!fragment(&diff), "{diff}");

        let updated = json!({"type": "update", "filePath": "/p/notes.md", "originalFile": "old\n"});
        let diff = write_settled("w2", "The file /p/notes.md has been updated.", Some(updated));
        assert_eq!(diff["oldText"], "old\n");
        assert!(!fragment(&diff), "{diff}");

        let diff = write_settled("w3", "The file /p/notes.md has been updated.", None);
        assert_eq!(diff["oldText"], Value::Null);
        assert!(fragment(&diff), "{diff}");

        // Cut off before its result: no diff at all, as for any edit.
        let [cut_off] = claude_tool_uses(&write("w4"), Some(1)).try_into().unwrap();
        assert_eq!(cut_off.done, json!({"status": "failed"}));
    }
}
