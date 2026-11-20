//! The task list from Claude Code's TaskCreate and TaskUpdate calls, as Claude
//! Code 2.1.312 sends them (captured from a real `-p` session).

use super::task_plan::TaskPlan;
use serde_json::{Value, json};

fn entries(plan: Option<Value>) -> Value {
    plan.expect("a plan update")["entries"].clone()
}

fn create(plan: &mut TaskPlan, tool: &str, subject: &str, id: &str) -> Option<Value> {
    plan.call(
        "TaskCreate",
        tool,
        &json!({"subject": subject, "description": format!("Run {subject}")}),
    );
    plan.result(tool, false, Some(&json!({"task": {"id": id, "subject": subject}})))
}

fn update(plan: &mut TaskPlan, tool: &str, id: &str, status: &str) -> Option<Value> {
    plan.call("TaskUpdate", tool, &json!({"taskId": id, "status": status}));
    plan.result(
        tool,
        false,
        Some(&json!({"success": true, "taskId": id, "updatedFields": ["status"]})),
    )
}

#[test]
fn creates_and_updates_draw_one_list_in_order() {
    let mut plan = TaskPlan::default();
    assert_eq!(
        entries(create(&mut plan, "c1", "echo a", "1")),
        json!([{"content": "echo a", "status": "pending", "priority": "medium"}])
    );
    create(&mut plan, "c2", "echo b", "2");
    create(&mut plan, "c3", "reply done", "3");
    update(&mut plan, "u1", "1", "in_progress");
    assert_eq!(
        entries(update(&mut plan, "u2", "1", "completed")),
        json!([
            {"content": "echo a", "status": "completed", "priority": "medium"},
            {"content": "echo b", "status": "pending", "priority": "medium"},
            {"content": "reply done", "status": "pending", "priority": "medium"},
        ])
    );
}

#[test]
fn results_out_of_order_apply_to_the_call_they_answer() {
    // Claude sent "2 completed" and "3 in progress" together; 3's result came first.
    let mut plan = TaskPlan::default();
    create(&mut plan, "c2", "echo b", "2");
    create(&mut plan, "c3", "reply done", "3");
    plan.call("TaskUpdate", "u2", &json!({"taskId": "2", "status": "completed"}));
    plan.call("TaskUpdate", "u3", &json!({"taskId": "3", "status": "in_progress"}));
    plan.result("u3", false, Some(&json!({"success": true})));
    assert_eq!(
        entries(plan.result("u2", false, Some(&json!({"success": true})))),
        json!([
            {"content": "echo b", "status": "completed", "priority": "medium"},
            {"content": "reply done", "status": "in_progress", "priority": "medium"},
        ])
    );
}

#[test]
fn a_failed_call_or_an_unknown_task_changes_nothing() {
    let mut plan = TaskPlan::default();
    create(&mut plan, "c1", "echo a", "1");
    plan.call("TaskUpdate", "u1", &json!({"taskId": "1", "status": "completed"}));
    assert_eq!(plan.result("u1", true, None), None);
    assert_eq!(update(&mut plan, "u2", "9", "completed"), None);
    // A create whose result names no id is not drawn.
    plan.call("TaskCreate", "c2", &json!({"subject": "echo b"}));
    assert_eq!(plan.result("c2", false, Some(&json!({}))), None);
    // A result for a call this list never held (a Bash call) is not its business.
    assert_eq!(plan.result("bash-1", false, None), None);
    // The same status again sends nothing new.
    assert_eq!(update(&mut plan, "u3", "1", "pending"), None);
}

#[test]
fn a_deleted_task_leaves_the_list_and_a_new_subject_renames_it() {
    let mut plan = TaskPlan::default();
    create(&mut plan, "c1", "echo a", "1");
    create(&mut plan, "c2", "echo b", "2");
    plan.call("TaskUpdate", "u1", &json!({"taskId": "2", "subject": "echo bee"}));
    assert_eq!(entries(plan.result("u1", false, None))[1]["content"], json!("echo bee"));
    assert_eq!(
        entries(update(&mut plan, "u2", "1", "deleted")),
        json!([{"content": "echo bee", "status": "pending", "priority": "medium"}])
    );
}

#[test]
fn follows_only_the_task_tools() {
    assert!(TaskPlan::follows("TaskCreate"));
    assert!(TaskPlan::follows("TaskUpdate"));
    assert!(!TaskPlan::follows("TaskList"));
    assert!(!TaskPlan::follows("Task"));
    assert!(!TaskPlan::follows("TodoWrite"));
}
