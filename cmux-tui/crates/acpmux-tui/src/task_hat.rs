//! The chat's task list over the composer, as the GUI chat's composer hat shows it (cmux da318d4,
//! 140c602; `webviews/.../chatTaskList.ts`). Leo, 2026-11-24: "in terminals and guis alike perhaps
//! terminal simply needs to also have the fixes and enhancements".
//!
//! acpmux keeps the list on the chat across turns (`acpmux::task_list`) and every session summary
//! carries it as `taskList`, already expired by turns. A turn's plan row in the transcript folds
//! when the turn ends and pages out of a long chat; this line stays, so between turns the person
//! sees what is done and what is next without scrolling back. It shows while steps are left.

use acpmux::task_list::{TaskListSummary, TaskStatus};
use serde_json::Value;

/// The summary's task list while steps are left, else None.
pub(crate) fn of(summary: &Value) -> Option<TaskListSummary> {
    let list: TaskListSummary = serde_json::from_value(summary.get("taskList")?.clone()).ok()?;
    let left = list.items.iter().any(|i| i.status != TaskStatus::Completed);
    (left && !list.items.is_empty()).then_some(list)
}

/// The hat's line: "Tasks 2/5 · ▸ current step · next: the step after".
pub(crate) fn line(list: &TaskListSummary) -> String {
    let mut out = format!("Tasks {}/{}", list.done, list.total);
    if let Some(now) = list.current.as_deref() {
        out.push_str(" · ▸ ");
        out.push_str(one_line(now).as_str());
    }
    if let Some(next) = list.next.as_deref() {
        out.push_str(" · next: ");
        out.push_str(one_line(next).as_str());
    }
    out
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn summary(items: Value, done: u32, current: Value, next: Value) -> Value {
        json!({"sessionId": "s", "taskList": {
            "source": "harness", "done": done, "total": items.as_array().unwrap().len(),
            "current": current, "next": next, "items": items, "updatedAt": 1
        }})
    }

    #[test]
    fn shows_steps_left_with_now_and_next() {
        let s = summary(
            json!([
                {"content": "Read the code", "status": "completed"},
                {"content": "Port the\nfix", "status": "in_progress"},
                {"content": "Open the PR", "status": "pending"}
            ]),
            1,
            json!("Port the\nfix"),
            json!("Open the PR"),
        );
        let list = of(&s).expect("steps are left");
        assert_eq!(line(&list), "Tasks 1/3 · ▸ Port the fix · next: Open the PR");
    }

    #[test]
    fn leaves_when_done_absent_or_malformed() {
        let done = summary(
            json!([{"content": "Ship", "status": "completed"}]),
            1,
            Value::Null,
            Value::Null,
        );
        assert!(of(&done).is_none());
        assert!(of(&json!({"sessionId": "s"})).is_none());
        assert!(of(&json!({"taskList": null})).is_none());
        assert!(of(&json!({"taskList": {"items": "nope"}})).is_none());
    }

    #[test]
    fn pending_only_names_next() {
        let s = summary(
            json!([{"content": "Later", "status": "pending"}]),
            0,
            Value::Null,
            json!("Later"),
        );
        assert_eq!(line(&of(&s).unwrap()), "Tasks 0/1 · next: Later");
    }
}
