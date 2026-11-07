//! The chat's own tool calls running in the foreground now, and how long each has run
//! ([`FOREGROUND_WORK`]): the hub moves the long ones to the background when the person's
//! message waits behind them (`hub/auto_background.rs`), since Claude Code reads a steer only
//! when its step ends (`steer_batch.rs`).
//!
//! A Bash or Agent call of the chat's own turn counts from when its call came until its result,
//! until Claude Code moves it to the background, or until the turn ends. A subagent's calls block
//! only their subagent, so they do not count; neither does a call started in the background
//! (`run_in_background`, or an Agent call Claude Code launched there itself), a Workflow (always
//! in the background) or a Monitor.

use super::*;

impl Translator {
    /// Notes a tool call of the chat's own turn as it comes (`inbound.rs`).
    pub(super) async fn foreground_call(&self, name: &str, id: &str, input: &Value) {
        if matches!(name, "Bash" | "Agent" | "Task")
            && input.get("run_in_background") != Some(&Value::Bool(true))
        {
            self.foreground_since.lock().await.insert(id.to_owned(), std::time::Instant::now());
        }
    }

    /// The result of tool call `id` came: it runs no more.
    pub(super) async fn foreground_done(&self, id: &str) {
        self.foreground_since.lock().await.remove(id);
    }

    /// The turn ended: none of its calls runs.
    pub(super) async fn foreground_ended(&self) {
        self.foreground_since.lock().await.clear();
    }

    /// [`FOREGROUND_WORK`]'s answer: the calls still in the foreground, a shell not moved and a
    /// subagent not in the background, with how long each has run. One lock at a time.
    pub(super) async fn foreground_work(&self) -> Value {
        let since: Vec<(String, std::time::Instant)> =
            self.foreground_since.lock().await.iter().map(|(t, at)| (t.clone(), *at)).collect();
        let shells: HashMap<String, bool> = {
            let shells = self.background_shells.lock().await;
            since.iter().filter_map(|(t, _)| Some((t.clone(), shells.get(t)?.background))).collect()
        };
        let agents: HashSet<String> = {
            let agents = self.subagents.lock().await;
            since.iter().filter(|(t, _)| agents.contains_key(t)).map(|(t, _)| t.clone()).collect()
        };
        let moved: HashSet<String> = {
            let moved = self.background_subagents.lock().await;
            agents.iter().filter(|t| moved.contains(*t)).cloned().collect()
        };
        let work: Vec<Value> = since
            .iter()
            .filter(|(t, _)| match shells.get(t) {
                Some(background) => !background,
                None => agents.contains(t) && !moved.contains(t),
            })
            .map(|(t, at)| {
                let ms = u64::try_from(at.elapsed().as_millis()).unwrap_or(u64::MAX);
                json!({"toolCallId": t, "runningMs": ms})
            })
            .collect();
        json!({"work": work})
    }
}
