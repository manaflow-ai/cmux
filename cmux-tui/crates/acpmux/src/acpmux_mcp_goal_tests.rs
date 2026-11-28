use super::*;

#[test]
fn each_tool_says_what_to_pass_and_the_result_reads_in_one_line() {
    let tools = tools();
    let names: Vec<&str> = tools.iter().filter_map(|t| t.get("name")?.as_str()).collect();
    assert_eq!(names, TOOLS);
    let set = tools.first().and_then(|t| t.pointer("/inputSchema/required"));
    assert_eq!(set, Some(&json!(["objective", "doneWhen"])));

    let goal = json!({"objective": "Ship it", "doneWhen": "CI green", "lifecycle": "running"});
    assert_eq!(describe("goal_set", &goal), "Goal set: Ship it. Done when: CI green.");
    assert_eq!(describe("goal_get", &goal), "Goal running: Ship it. Done when: CI green.");
    let done = json!({"objective": "Ship it", "lifecycle": "done"});
    assert_eq!(describe("goal_update", &done), "Goal complete: Ship it.");
    let spent = json!({"objective": "Ship it", "lifecycle": "stalled", "stopReason": "timeBudget"});
    assert_eq!(describe("goal_get", &spent), "Goal stopped (time budget spent): Ship it.");
    assert_eq!(describe("goal_get", &Value::Null), "This chat has no goal.");
}
