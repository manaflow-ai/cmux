use super::*;

/// A row with every field the daemon sends, with `files` and the text as long as a real
/// checkout makes them.
fn fat_row(i: usize) -> Value {
    let dir = format!("/home/agent/checkouts/some-repository/a-rather-long-worktree-name-{i}");
    let files: Vec<Value> = (0..40)
        .map(|f| json!({"repo": "some-repository", "path": format!("{dir}/crates/a-crate-with-a-long-name/src/a_module_with_a_long_name_{f}.rs")}))
        .collect();
    json!({
        "agoMs": 1000 + i, "branch": format!("a-long-branch-name-for-session-{i}"),
        "cwd": dir, "editedInCommon": 3, "files": files, "filesInCommon": 7,
        "harness": "claude", "host": format!("a-host-{i}"), "lastActiveAt": 1_764_000_000_000u64,
        "live": true, "name": format!("a-session-with-a-long-name-{i}"),
        "pullRequests": [{"url": "https://github.com/owner/repo/pull/12345"}],
        "ref": format!("a-host-{i}/a-session-with-a-long-name-{i}"),
        "sameBranch": false, "sameWorktree": false, "score": 90 - i as i64,
        "sessionId": format!("aid-{i:032x}"), "status": "working",
        "title": "A session title that runs on and on about what the agent is doing right now, \
        long enough to matter when forty of them arrive at once".to_owned(),
        "topicWords": ["acpmux", "mcp", "bound", "who", "else", "output"],
    })
}

fn fat_answer(n: usize) -> Value {
    let rows: Vec<Value> = (0..n).map(fat_row).collect();
    let lines: Vec<String> = (0..n)
        .map(|i| {
            format!("a-host-{i}/a-session-with-a-long-name-{i}  claude  working  7 files in common")
        })
        .collect();
    json!({
        "schema": "acpmux.who-else.v1",
        "query": {"files": [], "fileCount": 0, "topic": "acpmux", "branch": null, "worktree": null},
        "sessions": rows, "more": 0, "unreached": [], "lines": lines,
    })
}

#[test]
fn many_long_sessions_stay_under_the_bound_and_say_what_was_left_out() {
    let whole = fat_answer(60);
    // The bug this bounds: the whole answer is far past any caller's room.
    assert!(whole.to_string().chars().count() > 100_000);
    let short = brief(&whole);
    let len = short.to_string().chars().count();
    assert!(len <= MAX_CHARS, "bounded answer is {len} characters, over {MAX_CHARS}");
    let omitted = short.get("omitted").expect("the answer says what it left out");
    let n = |k: &str| omitted.get(k).and_then(Value::as_u64).unwrap();
    assert_eq!(n("bound"), MAX_CHARS as u64);
    assert!(n("sessions") > 0, "60 rows cannot fit, so some are counted out");
    assert!(n("listEntries") > 0, "40-file lists are cut, so their entries are counted out");
    assert_eq!(n("charactersOfWhole"), whole.to_string().chars().count() as u64);
    assert!(omitted.get("how").and_then(Value::as_str).unwrap().contains("detail: true"));
    // The cut is in the text an agent reads, not only in the structure.
    let text = text(&short);
    assert!(text.contains("left out"), "{text}");
    assert!(text.contains("detail: true"), "{text}");
    // Every row keeps every field name, so nothing a caller reads disappears.
    let before = fat_row(0).as_object().unwrap().keys().cloned().collect::<Vec<_>>();
    let after = short.get("sessions").and_then(Value::as_array).unwrap()[0]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(before, after);
    // The summary line of each kept row survives: that is the answer to "who owns this".
    let lines = short.get("lines").and_then(Value::as_array).unwrap();
    assert_eq!(lines.len(), short.get("sessions").and_then(Value::as_array).unwrap().len());
    assert!(!lines.is_empty(), "the bound never empties the summary");
}

#[test]
fn the_measured_call_six_sessions_of_detail_fits_and_keeps_every_line() {
    // The call that overflowed twice on one of our hosts had 6 lines and more: 0; the bulk
    // was per-session detail. Bounded, every line stays and only the detail is cut.
    let whole = fat_answer(6);
    let short = brief(&whole);
    assert!(short.to_string().chars().count() <= MAX_CHARS);
    assert_eq!(short.get("lines").and_then(Value::as_array).unwrap().len(), 6);
    assert_eq!(short.get("sessions").and_then(Value::as_array).unwrap().len(), 6);
    assert_eq!(short.get("omitted").unwrap().get("sessions").unwrap(), &json!(0));
    assert!(short.get("omitted").unwrap().get("listEntries").unwrap().as_u64().unwrap() > 0);
    // The cut names its tier, so six short rows read apart from six whole ones.
    let detail = short.get("omitted").unwrap().get("rowDetail").unwrap();
    assert!(detail.get("tier").unwrap().as_u64().unwrap() > 0, "{detail}");
    assert!(text(&short).contains("short form"));
}

#[test]
fn a_short_answer_is_unchanged_but_for_the_counts() {
    let whole = json!({
        "schema": "acpmux.who-else.v1", "sessions": [], "more": 0,
        "unreached": [{"host": "a-host", "error": "no answer in 5 s"}], "lines": [],
    });
    let short = brief(&whole);
    assert_eq!(short.get("sessions").unwrap(), &json!([]));
    assert_eq!(short.get("unreached").unwrap(), whole.get("unreached").unwrap());
    assert_eq!(short.get("omitted").unwrap().get("sessions").unwrap(), &json!(0));
    // Nothing was cut, so the text carries no cut note and still names the quiet peer.
    let text = text(&short);
    assert!(!text.contains("left out"), "{text}");
    assert!(text.contains("no answer in 5 s"), "{text}");
}

#[test]
fn the_daemons_own_ranked_out_count_is_carried_not_overwritten() {
    let mut whole = fat_answer(20);
    whole.as_object_mut().unwrap().insert("more".into(), json!(429));
    let short = brief(&whole);
    let omitted = short.get("omitted").unwrap();
    assert_eq!(omitted.get("rankedOut").unwrap(), &json!(429));
    let kept = short.get("sessions").and_then(Value::as_array).unwrap().len();
    let dropped = 20 - kept;
    assert_eq!(short.get("more").unwrap(), &json!(429 + dropped as u64));
}

#[test]
fn the_bound_and_the_way_to_the_rest_are_in_the_tools_own_description() {
    let tool = tool();
    let description = tool.get("description").and_then(Value::as_str).unwrap();
    assert!(description.contains(&MAX_CHARS.to_string()), "{description}");
    assert!(description.contains("detail: true"), "{description}");
    let detail = &tool["inputSchema"]["properties"]["detail"];
    assert_eq!(detail.get("type").unwrap(), &json!("boolean"));
    assert!(detail.get("description").and_then(Value::as_str).unwrap().contains("whole"));
}

#[test]
fn clip_cuts_on_a_character_and_marks_the_cut() {
    assert_eq!(clip("short", 10), "short");
    assert_eq!(clip("ααααα", 3), "αα…");
    assert_eq!(clip("abcdef", 6), "abcdef");
}
