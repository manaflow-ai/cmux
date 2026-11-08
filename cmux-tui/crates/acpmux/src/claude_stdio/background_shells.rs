//! Claude's background shells (cx-ncc.84): a Bash or Monitor call Claude runs
//! in the background, from its task events to the `background_task_update`s
//! the hub lists as processes (`hub/processes.rs`). A workflow agent's shell
//! goes to its workflow's session and names its agent (`shell_owner`), so
//! Session Info and Background tasks list it under that agent.

use super::*;
use std::path::{Path, PathBuf};

/// The most of the end of each agent transcript read when looking for the
/// Bash call a workflow agent's shell came from (`shell_owner`): the call is
/// the agent's latest, so it is near the end.
const OWNER_TAIL: u64 = 512 << 10;
/// How many times a workflow agent's shell is looked for in the run's
/// transcripts: when it is announced, then on the run's snapshots and at its
/// end while its call is not written yet.
pub(super) const OWNER_TRIES: u8 = 4;

/// A running shell: the session its Bash call ran in, its command, Claude's
/// task id once a task event named it, and whether it runs in the background.
#[derive(Debug, Clone)]
pub(super) struct BackgroundShell {
    pub(super) sid: String,
    pub(super) command: String,
    /// What the Bash call says it does (its `description`): the tray names
    /// the process by it (webviews `session-info/commandRules.ts`).
    pub(super) description: Option<String>,
    pub(super) task: Option<String>,
    pub(super) background: bool,
    /// Started in the background (`run_in_background`), not moved there.
    pub(super) launched: bool,
    /// The person asked for it to go to the background (`BACKGROUND_TASKS`):
    /// once it moves, its origin is `user_backgrounded`.
    pub(super) asked: bool,
    /// Its `running` update went out (`running`).
    pub(super) announced: bool,
    /// The file Claude Code writes its output to (`output_file`), once a
    /// task event named it.
    pub(super) output: Option<String>,
    /// A workflow agent's shell: Claude's task_started says only
    /// `owned_by_subagent`, with no `parent_task_id` (that names a plain
    /// subagent) and no `parent_tool_use_id`. Its workflow and agent are
    /// found from the run's transcripts (`shell_owner`).
    pub(super) workflow_owned: bool,
    /// Claude's id of the workflow agent whose Bash call started it, once
    /// found: `workflowAgentId` on its updates.
    pub(super) workflow_agent: Option<String>,
    /// How many times its workflow agent was looked for (`OWNER_TRIES`).
    pub(super) owner_tries: u8,
}

impl Translator {
    /// Claude's task events for a shell (cx-ncc.84): a `local_bash`
    /// task_started names its task and says whether it runs in the background,
    /// a task_updated may move it there (either way a `running`
    /// `background_task_update` goes out once), and a background one's
    /// `task_notification`, or a task_updated whose patch says it was stopped
    /// (Claude Code may send no notification after `stop_task`), returns a
    /// `background_task_update` saying how it ended (`completed`, `failed`
    /// or `stopped`), with Claude's reason or summary when it gave one. The
    /// update goes to the session the shell's Bash call ran in, a
    /// subagent's too. A shell ends once: a later end finds no shell.
    pub(super) async fn background_shell_task(
        &self,
        sub: &str,
        line: &Value,
        sid: &str,
    ) -> Option<Message> {
        let text = |key: &str| line.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
        let task = text("task_id");
        let mut shells = self.background_shells.lock().await;
        // A task_updated or notification may name only the task.
        let tool = match text("tool_use_id") {
            Some(tool) => tool.to_owned(),
            None => {
                let task = task?;
                shells.iter().find(|(_, s)| s.task.as_deref() == Some(task))?.0.clone()
            }
        };
        let backgrounded = |at: Option<&Value>| at == Some(&Value::Bool(true));
        // How it ended: a notification's status, or a task_updated patch's.
        let status = match sub {
            "task_updated" => line.pointer("/patch/status").and_then(Value::as_str),
            _ => text("status"),
        };
        match sub {
            "task_started" if text("task_type") == Some("local_bash") => {
                // Only a workflow agent's shell is owned by a subagent with no parent task and
                // no parent call: a plain subagent's names its task, its lines their call.
                let workflow_owned = line.get("owned_by_subagent") == Some(&Value::Bool(true))
                    && text("parent_task_id").is_none()
                    && text("parent_tool_use_id").is_none();
                let shell = shells.entry(tool.clone()).or_insert_with(|| BackgroundShell {
                    sid: sid.to_owned(),
                    command: text("description").unwrap_or("").to_owned(),
                    description: None,
                    task: None,
                    background: false,
                    launched: backgrounded(line.get("is_backgrounded")),
                    asked: false,
                    announced: false,
                    output: None,
                    workflow_owned,
                    workflow_agent: None,
                    owner_tries: 0,
                });
                shell.task = task.map(str::to_owned).or(shell.task.take());
                shell.output = text("output_file").map(str::to_owned).or(shell.output.take());
                shell.background |= backgrounded(line.get("is_backgrounded"));
                return self.announce(&tool, shells).await;
            }
            "task_updated" => {
                let shell = shells.get_mut(&tool)?;
                shell.background |= backgrounded(line.pointer("/patch/is_backgrounded"));
                shell.output = text("output_file").map(str::to_owned).or(shell.output.take());
                // Claude Code may send no notification after `stop_task`: a
                // stopped task ends here. A completed or failed one waits
                // for its notification, which carries the summary.
                if !matches!(status, Some("stopped" | "killed")) {
                    return self.announce(&tool, shells).await;
                }
            }
            "task_notification" => {}
            _ => return None,
        }
        let mut shell = shells.remove(&tool).filter(|s| s.background)?;
        drop(shells);
        // A workflow agent's shell whose agent was not found yet: its end names it if it can.
        if shell.workflow_owned
            && shell.workflow_agent.is_none()
            && shell.owner_tries < OWNER_TRIES
            && let Some((child, Some(agent))) = self.shell_owner(&tool).await
        {
            shell.sid = child;
            shell.workflow_agent = Some(agent);
        }
        shell.output = text("output_file").map(str::to_owned).or(shell.output.take());
        let state = match status {
            Some("failed") => "failed",
            Some("killed" | "stopped") => "stopped",
            _ => "completed",
        };
        let mut update = background_task_update(&tool, &shell, state);
        if let Some(task) = task {
            update.set("taskId", json!(task));
        }
        for key in ["reason", "summary"] {
            if let Some(value) = text(key) {
                update.set(key, json!(value));
            }
        }
        // Claude Code says a shell's exit code only in its summary
        // ("Background command \"x\" completed (exit code 0)"); Codex's
        // updates carry it as `exitCode`, and clients read it there.
        if let Some(code) = text("summary").and_then(super::inbound::summary_exit_code) {
            update.set("exitCode", json!(code));
        }
        Some(shell_update(&shell, update))
    }

    /// The `running` update of the shell `tool` (`running`). A workflow
    /// agent's shell goes out in its workflow's session, naming its agent,
    /// when the run's transcripts say which agent's Bash call it was
    /// (`shell_owner`); the lookup runs once, when the shell is first
    /// announced, never for a foreground shell.
    async fn announce(
        &self,
        tool: &str,
        mut shells: tokio::sync::MutexGuard<'_, HashMap<String, BackgroundShell>>,
    ) -> Option<Message> {
        let shell = shells.get(tool)?;
        if shell.background && !shell.announced && shell.workflow_owned && shell.owner_tries == 0 {
            drop(shells);
            let owner = self.shell_owner(tool).await;
            shells = self.background_shells.lock().await;
            let shell = shells.get_mut(tool)?;
            shell.owner_tries += 1;
            if let Some((child, agent)) = owner {
                shell.sid = child;
                shell.workflow_agent = agent;
            }
        }
        running(tool, shells.get_mut(tool)?)
    }

    /// Workflow agents' running shells announced before their agent was
    /// found (its Bash call was not in its transcript yet), looked for again
    /// on a run's snapshot, `OWNER_TRIES` times at most in all. One found
    /// goes out again as `running`, naming its workflow and agent: the hub
    /// keeps them on the process (`hub/processes.rs`), and clients note only
    /// how a shell ended.
    pub(super) async fn attribute_workflow_shells(&self) -> Vec<Message> {
        let waiting: Vec<String> = self
            .background_shells
            .lock()
            .await
            .iter()
            .filter(|(_, s)| {
                s.announced
                    && s.workflow_owned
                    && s.workflow_agent.is_none()
                    && s.owner_tries < OWNER_TRIES
            })
            .map(|(tool, _)| tool.clone())
            .collect();
        let mut out = Vec::new();
        for tool in waiting {
            let owner = self.shell_owner(&tool).await;
            let mut shells = self.background_shells.lock().await;
            let Some(shell) = shells.get_mut(&tool) else { continue };
            shell.owner_tries += 1;
            let Some((child, Some(agent))) = owner else { continue };
            shell.sid = child;
            shell.workflow_agent = Some(agent);
            let mut update = background_task_update(&tool, shell, "running");
            update.set("origin", json!(origin(shell)));
            out.push(shell_update(shell, update));
        }
        out
    }

    /// The background shells still running when Claude's stdout closed: they
    /// ended with its process, so each is reported `stopped`, marked
    /// `_meta.acpmux.endedBy: "harness_exit"` for the hub (`hub/processes.rs`
    /// lists it `lost`); the update itself is what clients show. A call named
    /// early whose input was still streaming ends `failed` with them, and its
    /// loops end with it too (`loops.rs`).
    pub async fn end_background_shells(&self) -> Vec<Message> {
        let mut shells: Vec<_> =
            self.background_shells.lock().await.drain().filter(|(_, s)| s.background).collect();
        shells.sort_by(|a, b| a.0.cmp(&b.0));
        let mut out = self.end_all_announced().await;
        out.extend(shells.into_iter().map(|(tool, shell)| {
            let update = background_task_update(&tool, &shell, "stopped");
            Message::notification(
                method::SESSION_UPDATE,
                json!({"sessionId": shell.sid, "update": update,
                           "_meta": {"acpmux": {"endedBy": "harness_exit"}}}),
            )
        }));
        out.extend(self.end_loops().await);
        out
    }
}

impl Translator {
    /// The workflow a workflow agent's shell belongs to, as the workflow's
    /// subagent session, and the agent whose Bash call `tool` started it, by
    /// Claude's agent id. Claude's task_started for such a shell says only
    /// `owned_by_subagent` (Claude Code 2.1.312), so the agent is the one
    /// whose transcript in a running workflow's dir (`agent-<id>.jsonl`) has
    /// the call. Not found: the only running workflow with no agent, or
    /// nothing when several run.
    pub(super) async fn shell_owner(&self, tool: &str) -> Option<(String, Option<String>)> {
        let runs: Vec<(String, Option<PathBuf>)> = self
            .workflows
            .lock()
            .await
            .iter()
            .map(|(call, run)| (call.clone(), run.dir.clone()))
            .collect();
        let dirs: Vec<(String, PathBuf)> =
            runs.iter().filter_map(|(call, dir)| Some((call.clone(), dir.clone()?))).collect();
        let found = match dirs.is_empty() {
            true => None,
            false => {
                let tool = tool.to_owned();
                // Off the stdout loop: a few files' ends.
                tokio::task::spawn_blocking(move || {
                    dirs.into_iter().find_map(|(call, dir)| {
                        agent_of_call(&dir, &tool).map(|agent| (call, agent))
                    })
                })
                .await
                .ok()
                .flatten()
            }
        };
        let (call, agent) = match found {
            Some((call, agent)) => (call, Some(agent)),
            None if runs.len() == 1 => (runs[0].0.clone(), None),
            None => return None,
        };
        let child = self.subagents.lock().await.get(&call)?.clone();
        Some((child, agent))
    }
}

/// The agent of a workflow run whose transcript in `dir`
/// (`agent-<id>.jsonl`) has the tool call `tool` near its end, the most
/// recently written transcript first.
pub(super) fn agent_of_call(dir: &Path, tool: &str) -> Option<String> {
    let needle = format!("\"id\":\"{tool}\"");
    let mut files: Vec<(std::time::SystemTime, PathBuf, String)> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let name = entry.file_name().into_string().ok()?;
            let agent = name.strip_prefix("agent-")?.strip_suffix(".jsonl")?.to_owned();
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((modified, entry.path(), agent))
        })
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.into_iter().find(|(_, path, _)| tail_has(path, needle.as_bytes())).map(|(_, _, a)| a)
}

/// Whether the last `OWNER_TAIL` bytes of the file at `path` hold `needle`.
fn tail_has(path: &Path, needle: &[u8]) -> bool {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = std::fs::File::open(path) else { return false };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    if file.seek(SeekFrom::Start(len.saturating_sub(OWNER_TAIL))).is_err() {
        return false;
    }
    let mut bytes = Vec::new();
    if file.take(OWNER_TAIL).read_to_end(&mut bytes).is_err() {
        return false;
    }
    bytes.windows(needle.len()).any(|w| w == needle)
}

/// A `background_task_update` for one shell.
pub(super) fn background_task_update(tool: &str, shell: &BackgroundShell, state: &str) -> Value {
    let mut update = json!({
        "sessionUpdate": "background_task_update",
        "taskId": shell.task.as_deref().unwrap_or(""),
        "toolCallId": tool,
        "command": shell.command,
        "state": state,
    });
    // The workflow agent whose Bash call started it (`shell_owner`).
    if let Some(agent) = &shell.workflow_agent {
        update.set("workflowAgentId", json!(agent));
    }
    // The call's own words for it, so a client that never loaded the call
    // (an older page, a peer) still names it by them.
    if let Some(description) = &shell.description {
        update.set("description", json!(description));
    }
    update
}

/// The `running` update of a shell Claude runs in the background now, once
/// per shell, with its `origin`: the hub lists it as a process
/// (`hub/processes.rs`) and keeps a chat with one alive (`hub/idle.rs`).
/// Clients note only how a shell ended.
fn running(tool: &str, shell: &mut BackgroundShell) -> Option<Message> {
    if !shell.background || shell.announced {
        return None;
    }
    shell.announced = true;
    let mut update = background_task_update(tool, shell, "running");
    update.set("origin", json!(origin(shell)));
    Some(shell_update(shell, update))
}

/// How a shell got to the background: `background` when it started there,
/// `user_backgrounded` when the person moved it (Ctrl-B), else
/// `auto_backgrounded` (Claude Code moved it).
pub(super) fn origin(shell: &BackgroundShell) -> &'static str {
    match (shell.launched, shell.asked) {
        (true, _) => "background",
        (false, true) => "user_backgrounded",
        (false, false) => "auto_backgrounded",
    }
}

/// `update` as a session update in the shell's session, with its output
/// file once Claude named it as `_meta.acpmux.outputFile`, which the hub
/// takes off before the update is logged (`hub/processes.rs`): the path
/// stays in the registry.
pub(super) fn shell_update(shell: &BackgroundShell, update: Value) -> Message {
    let mut params = json!({"sessionId": shell.sid, "update": update});
    if let Some(output) = &shell.output {
        params.set("_meta", json!({"acpmux": {"outputFile": output}}));
    }
    Message::notification(method::SESSION_UPDATE, params)
}
