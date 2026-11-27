//! Claude Code's /loop as the chat's goal (`loops.rs`). Lines as Claude Code 2.1.310 writes them:
//! a ScheduleWakeup or CronCreate `tool_use`, then its `tool_result` with the tool's data in the
//! line's `tool_use_result`.

use super::*;

/// The `_meta.goal` of each update a line made: `Some(Null)` is a cleared goal.
async fn goals(t: &Translator, line: Value) -> Vec<Value> {
    t.inbound(&line)
        .await
        .iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => {
                let update = params.as_ref()?.get("update")?;
                (update.get("sessionUpdate")? == "session_info_update")
                    .then(|| update.pointer("/_meta/goal").cloned())
                    .flatten()
            }
            _ => None,
        })
        .collect()
}

fn call(id: &str, name: &str, input: Value) -> Value {
    json!({"type": "assistant", "parent_tool_use_id": null, "message": {"id": format!("m-{id}"), "content": [
        {"type": "tool_use", "id": id, "name": name, "input": input}
    ]}})
}

fn result(id: &str, data: Value) -> Value {
    json!({"type": "user", "parent_tool_use_id": null, "message": {"content": [
        {"type": "tool_result", "tool_use_id": id, "content": "ok"}
    ]}, "tool_use_result": data})
}

fn failed(id: &str) -> Value {
    json!({"type": "user", "parent_tool_use_id": null, "message": {"content": [
        {"type": "tool_result", "tool_use_id": id, "content": "refused", "is_error": true}
    ]}})
}

fn translator() -> Arc<Translator> {
    Translator::new("acp-1".into(), "default", "sonnet", "default")
}

#[tokio::test]
async fn a_scheduled_wakeup_is_the_chats_loop_with_its_next_run() {
    let t = translator();
    let input = json!({"delaySeconds": 270, "reason": "deploy still rolling out",
        "prompt": "check the deploy", "noop": false});
    assert_eq!(goals(&t, call("w1", "ScheduleWakeup", input)).await, Vec::<Value>::new());
    let got = goals(
        &t,
        result("w1", json!({"scheduledFor": 1_790_000_270_000u64, "clampedDelaySeconds": 270, "wasClamped": false})),
    )
    .await;
    assert_eq!(
        got,
        vec![json!({"kind": "loop", "status": "active", "objective": "check the deploy",
            "reason": "deploy still rolling out", "nextRunAt": 1_790_000_270_000u64,
            "timers": [{"at": 1_790_000_270_000u64, "recurring": false}]})]
    );
}

#[tokio::test]
async fn the_next_wakeup_moves_the_next_run_and_stop_clears_the_loop() {
    let t = translator();
    let arm = |id: &str, at: u64| {
        let t = t.clone();
        let id = id.to_owned();
        async move {
            goals(&t, call(&id, "ScheduleWakeup", json!({"delaySeconds": 60, "reason": "r", "prompt": "/loop tidy", "noop": true}))).await;
            goals(
                &t,
                result(
                    &id,
                    json!({"scheduledFor": at, "clampedDelaySeconds": 60, "wasClamped": false}),
                ),
            )
            .await
        }
    };
    assert_eq!(arm("w1", 1_000).await[0]["nextRunAt"], json!(1_000));
    let second = arm("w2", 2_000).await;
    assert_eq!(second[0]["nextRunAt"], json!(2_000));
    // "/loop tidy" is the loop's input: its words are the loop's.
    assert_eq!(second[0]["objective"], json!("tidy"));
    goals(&t, call("w3", "ScheduleWakeup", json!({"stop": true}))).await;
    let stopped = goals(&t, result("w3", json!({"scheduledFor": 0, "clampedDelaySeconds": 0, "wasClamped": false, "stopped": true, "cancelledWakeups": 1}))).await;
    assert_eq!(stopped, vec![Value::Null]);
}

#[tokio::test]
async fn an_autonomous_loop_names_no_prompt() {
    let t = translator();
    goals(&t, call("w1", "ScheduleWakeup", json!({"delaySeconds": 600, "reason": "r", "prompt": "<<loop.md-dynamic>>", "noop": false}))).await;
    let got = goals(
        &t,
        result("w1", json!({"scheduledFor": 5, "clampedDelaySeconds": 600, "wasClamped": false})),
    )
    .await;
    assert_eq!(got[0]["objective"], json!(""));
    assert_eq!(got[0]["autonomous"], json!(true));
}

#[tokio::test]
async fn a_refused_wakeup_arms_nothing() {
    let t = translator();
    goals(
        &t,
        call(
            "w1",
            "ScheduleWakeup",
            json!({"delaySeconds": 60, "reason": "r", "prompt": "p", "noop": false}),
        ),
    )
    .await;
    assert_eq!(goals(&t, failed("w1")).await, Vec::<Value>::new());
}

#[tokio::test]
async fn a_recurring_cron_is_a_loop_until_its_delete() {
    let t = translator();
    goals(&t, call("c1", "CronCreate", json!({"cron": "*/5 * * * *", "prompt": "/babysit-prs"})))
        .await;
    let got = goals(&t, result("c1", json!({"id": "job-7", "humanSchedule": "every 5 minutes", "recurring": true, "nextFireAt": 9_000}))).await;
    assert_eq!(
        got,
        vec![json!({"kind": "loop", "status": "active", "objective": "/babysit-prs",
            "schedule": "every 5 minutes", "nextRunAt": 9_000,
            "timers": [{"at": 9_000, "recurring": true}]})]
    );
    // Another job's delete leaves it.
    goals(&t, call("d0", "CronDelete", json!({"id": "job-other"}))).await;
    assert_eq!(goals(&t, result("d0", json!({"id": "job-other"}))).await, Vec::<Value>::new());
    goals(&t, call("d1", "CronDelete", json!({"id": "job-7"}))).await;
    assert_eq!(goals(&t, result("d1", json!({"id": "job-7"}))).await, vec![Value::Null]);
}

#[tokio::test]
async fn a_one_shot_cron_is_not_a_loop() {
    let t = translator();
    goals(
        &t,
        call(
            "c1",
            "CronCreate",
            json!({"cron": "30 14 28 2 *", "prompt": "remind me", "recurring": false}),
        ),
    )
    .await;
    let got = goals(
        &t,
        result("c1", json!({"id": "job-1", "humanSchedule": "once", "recurring": false})),
    )
    .await;
    assert_eq!(got, Vec::<Value>::new());
}

#[tokio::test]
async fn stopping_one_loop_shows_the_one_still_armed() {
    let t = translator();
    goals(&t, call("c1", "CronCreate", json!({"cron": "*/5 * * * *", "prompt": "cron work"})))
        .await;
    goals(
        &t,
        result("c1", json!({"id": "job-1", "humanSchedule": "every 5 minutes", "recurring": true})),
    )
    .await;
    goals(
        &t,
        call(
            "w1",
            "ScheduleWakeup",
            json!({"delaySeconds": 60, "reason": "r", "prompt": "wake work", "noop": false}),
        ),
    )
    .await;
    let both = goals(
        &t,
        result("w1", json!({"scheduledFor": 7, "clampedDelaySeconds": 60, "wasClamped": false})),
    )
    .await;
    assert_eq!(both[0]["objective"], json!("wake work"));
    // Both loops' timers, the cron's (no next fire said) and the wakeup's: Claude holds both.
    assert_eq!(both[0]["timers"], json!([{"recurring": true}, {"at": 7, "recurring": false}]));
    goals(&t, call("w2", "ScheduleWakeup", json!({"stop": true}))).await;
    let left = goals(&t, result("w2", json!({"stopped": true, "scheduledFor": 0}))).await;
    assert_eq!(left[0]["objective"], json!("cron work"));
}

#[tokio::test]
async fn claudes_exit_ends_its_loops() {
    let t = translator();
    goals(
        &t,
        call(
            "w1",
            "ScheduleWakeup",
            json!({"delaySeconds": 60, "reason": "r", "prompt": "p", "noop": false}),
        ),
    )
    .await;
    goals(
        &t,
        result("w1", json!({"scheduledFor": 7, "clampedDelaySeconds": 60, "wasClamped": false})),
    )
    .await;
    let ended: Vec<Value> = t
        .end_background_shells()
        .await
        .iter()
        .filter_map(|m| match m {
            Message::Notification { params, .. } => params
                .as_ref()?
                .pointer("/update/_meta")
                .filter(|m| m.get("goal").is_some())
                .cloned(),
            _ => None,
        })
        .collect();
    assert_eq!(ended, vec![json!({"goal": null})]);
    // With no loop armed, an exit says nothing of a goal (a Codex-style goal is not Claude's to clear).
    let t = translator();
    assert!(t.end_background_shells().await.is_empty());
}

/// A `scheduled_tasks.json` as Claude Code 2.1.332 writes it, with the 2026-11-26 coordinator's
/// cron (created by `cc-1` in an earlier process) and tasks that are not this chat's loops.
fn scheduled_tasks(dir: &std::path::Path, tasks: Value) {
    std::fs::create_dir_all(dir.join(".claude")).unwrap();
    std::fs::write(dir.join(".claude/scheduled_tasks.json"), json!({"tasks": tasks}).to_string())
        .unwrap();
}

fn coordinator_cron() -> Value {
    json!({"id": "70042717", "cron": "53 1-23/2 * * *", "prompt": "2-hour report is due",
        "createdAt": 1_795_290_868_080u64, "lastFiredAt": 1_795_675_310_869u64, "recurring": true,
        "createdBySessionId": "cc-1", "createdByPid": 402870, "createdInProject": "/p",
        "maxAgeMs": 2_592_000_000u64})
}

fn init(cwd: &std::path::Path) -> Value {
    json!({"type": "system", "subtype": "init", "session_id": "cc-1", "cwd": cwd.to_str().unwrap()})
}

#[test]
fn durable_tasks_are_this_conversations_recurring_live_ones() {
    let now = 1_795_675_000_000u64;
    let mut other = coordinator_cron();
    other.set("id", json!("other"));
    other.set("createdBySessionId", json!("cc-2"));
    let mut once = coordinator_cron();
    once.set("id", json!("once"));
    once.set("recurring", Value::Null);
    let mut aged = coordinator_cron();
    aged.set("id", json!("aged"));
    aged.set("maxAgeMs", json!(1000));
    let text = json!({"tasks": [coordinator_cron(), other, once, aged]}).to_string();
    let got = super::loops::durable_tasks(&text, "cc-1", now);
    assert_eq!(
        got,
        vec![(
            "cron:70042717".to_owned(),
            json!({"kind": "loop", "status": "active", "objective": "2-hour report is due",
                "schedule": "53 1-23/2 * * *"})
        )]
    );
    assert!(super::loops::durable_tasks("not json", "cc-1", now).is_empty());
}

/// Before: a resumed Claude never calls CronCreate for its durable cron, so its init armed no
/// timer and the idle reaper slept the chat through the cron's fire times (`agent_timer.rs`).
#[tokio::test]
async fn a_resumed_process_arms_the_durable_cron_it_made_before() {
    let dir = tempfile::tempdir().unwrap();
    scheduled_tasks(dir.path(), json!([coordinator_cron()]));
    let t = translator();
    let got = goals(&t, init(dir.path())).await;
    assert_eq!(
        got,
        vec![json!({"kind": "loop", "status": "active", "objective": "2-hour report is due",
            "schedule": "53 1-23/2 * * *", "timers": [{"recurring": true}]})]
    );
    // Every turn's init reads it again: nothing changed, no update.
    assert_eq!(goals(&t, init(dir.path())).await, Vec::<Value>::new());
    // Its CronDelete disarms it like a cron this process made.
    goals(&t, call("d1", "CronDelete", json!({"id": "70042717"}))).await;
    assert_eq!(goals(&t, result("d1", json!({"id": "70042717"}))).await, vec![Value::Null]);
}

#[tokio::test]
async fn a_durable_task_gone_from_the_file_disarms_and_none_arms_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let t = translator();
    // No file: no loop.
    assert_eq!(goals(&t, init(dir.path())).await, Vec::<Value>::new());
    scheduled_tasks(dir.path(), json!([coordinator_cron()]));
    assert_eq!(goals(&t, init(dir.path())).await.len(), 1);
    // Deleted in another process of the same conversation: the next init clears it.
    scheduled_tasks(dir.path(), json!([]));
    assert_eq!(goals(&t, init(dir.path())).await, vec![Value::Null]);
}

#[tokio::test]
async fn a_cron_this_process_made_keeps_its_goal_over_the_files() {
    let dir = tempfile::tempdir().unwrap();
    let t = translator();
    goals(
        &t,
        call(
            "c1",
            "CronCreate",
            json!({"cron": "53 1-23/2 * * *", "prompt": "fresh", "durable": true}),
        ),
    )
    .await;
    goals(
        &t,
        result(
            "c1",
            json!({"id": "70042717", "humanSchedule": "every 2 hours", "recurring": true,
            "nextFireAt": 9}),
        ),
    )
    .await;
    scheduled_tasks(dir.path(), json!([coordinator_cron()]));
    // Armed already, with the next fire Claude said: the file's copy changes nothing.
    assert_eq!(goals(&t, init(dir.path())).await, Vec::<Value>::new());
}
