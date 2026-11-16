use serde_json::{Value, json};

/// The tool name DeepSeek Harness gives its todo tool (`dsh-tool-todo`).
const TODO_WRITE: &str = "todo_write";

/// The most calls one chat holds waiting on their results; past it the oldest are dropped.
const MAX_HELD: usize = 64;

/// One chat's todo calls still running, by tool call id, each with the list it sends and the
/// call's own fields (title, kind, input), which a failed result shows its row with.
#[derive(Debug, Default)]
pub struct Watch {
    calls: Vec<(String, Vec<Value>, Value)>,
}

/// The fields of a call its row is drawn from, for a failed result that names none of them.
fn call_fields(update: &Value) -> Value {
    let mut fields = serde_json::Map::new();
    for key in ["title", "kind", "rawInput"] {
        if let Some(v) = update.get(key) {
            fields.insert(key.to_owned(), v.clone());
        }
    }
    Value::Object(fields)
}

/// The list a `todo_write` call's input sends, as ACP plan entries; none when it is not one.
pub fn entries(update: &Value) -> Option<Vec<Value>> {
    if update.get("title").and_then(Value::as_str).map(str::trim) != Some(TODO_WRITE) {
        return None;
    }
    let todos = update.pointer("/rawInput/todos")?.as_array()?;
    todos
        .iter()
        .map(|todo| {
            let content = todo.get("content")?.as_str()?.trim();
            let status = match todo.get("status")?.as_str()? {
                s @ ("pending" | "in_progress" | "completed") => s,
                _ => return None,
            };
            (!content.is_empty())
                .then(|| json!({"content": content, "priority": "medium", "status": status}))
        })
        .collect()
}

/// Marks an update as a todo call the checklist stands for (the pane draws no row for it).
fn mark(update: &mut Value) {
    if let Some(o) = update.as_object_mut() {
        let meta = o.entry("_meta").or_insert_with(|| json!({}));
        if let Some(m) = meta.as_object_mut() {
            let acpmux = m.entry("acpmux").or_insert_with(|| json!({}));
            if let Some(a) = acpmux.as_object_mut() {
                a.insert("planTool".to_owned(), json!(true));
            }
        }
    }
}

impl Watch {
    pub fn is_empty(&self) -> bool {
        self.calls.is_empty()
    }

    /// A live `session/update` of the chat's own thread: marks a todo call and its result, and
    /// returns the `plan` update a completed one makes.
    pub fn observe(&mut self, update: &mut Value) -> Option<Value> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str)?;
        if !matches!(kind, "tool_call" | "tool_call_update") {
            return None;
        }
        let id = update.get("toolCallId").and_then(Value::as_str)?.to_owned();
        if kind == "tool_call" {
            // A call under an id seen before is a new call: an adapter may number calls per run.
            self.calls.retain(|(held, _, _)| *held != id);
            if let Some(list) = entries(update) {
                if self.calls.len() >= MAX_HELD {
                    self.calls.remove(0);
                }
                self.calls.push((id.clone(), list, call_fields(update)));
            }
        }
        let at = self.calls.iter().position(|(held, _, _)| *held == id)?;
        mark(update);
        match update.get("status").and_then(Value::as_str) {
            Some("completed") => {
                let (_, list, _) = self.calls.remove(at);
                Some(json!({"sessionUpdate": "plan", "entries": list}))
            }
            Some("failed") => {
                // The pane hid the call, so its failed result brings back what the row shows.
                let (_, _, fields) = self.calls.remove(at);
                if let (Some(o), Value::Object(fields)) = (update.as_object_mut(), fields) {
                    for (key, value) in fields {
                        o.entry(key).or_insert(value);
                    }
                }
                None
            }
            _ => None,
        }
    }
}
