use super::*;

const NOW: u64 = 10_000_000_000;

/// `n` tasks oldest first, as the daemon lists them, each with a long command and tail.
fn listed(n: usize) -> Value {
    let tasks: Vec<Value> = (0..n)
        .map(|i| {
            json!({"id": format!("t{i}"), "state": if i % 2 == 0 { "exited" } else { "running" },
                "exitCode": if i % 2 == 0 { json!(i % 4) } else { Value::Null },
                "startedAt": NOW - 7_200_000, "endedAt": if i % 2 == 0 { json!(NOW - 60_000) } else { Value::Null },
                "command": format!("cargo test {}", "x".repeat(5000)), "tail": "y".repeat(1024)})
        })
        .collect();
    json!({"tasks": tasks, "otherOwners": 0})
}

fn page(args: Value) -> Page {
    let mut args = args;
    let page = Page::take(&mut args).unwrap();
    assert!(args.get("limit").is_none() && args.get("state").is_none(), "{args}");
    page
}

/// A bare call over a chat of 1,000 tasks answers the newest 30, one short line each, and a
/// last line naming the rest and how to see them; the whole result stays small.
#[test]
fn a_bare_list_is_the_newest_thirty_compact_lines() {
    let (structured, text) = page(json!({})).apply(listed(1000), NOW);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 31, "{text}");
    assert!(lines[0].starts_with("t999  [running]  started 2h ago  cargo test x"), "{}", lines[0]);
    assert!(lines[1].starts_with("t998  [exited (exit 2)]  ended 1m ago  "), "{}", lines[1]);
    assert!(lines[..30].iter().all(|l| l.chars().count() < 180), "{text}");
    assert!(
        lines[30].starts_with("970 older tasks not shown: offset: 30 lists the next 30;"),
        "{}",
        lines[30]
    );
    assert_eq!(structured["tasks"].as_array().unwrap().len(), 30);
    assert_eq!(
        (structured["total"].clone(), structured["more"].clone()),
        (json!(1000), json!(970))
    );
    assert!(structured["tasks"][0].get("tail").is_none());
    let size = text.len() + structured.to_string().len();
    assert!(size < 20_000, "{size} characters");
}

/// offset, limit and state pick the page; full brings back command and tail; a misspelt
/// state is read as its one close match and said so; a bad one is refused with the choices.
#[test]
fn offset_limit_state_and_full_pick_the_page() {
    let (s, text) = page(json!({"offset": 990, "limit": "20"})).apply(listed(1000), NOW);
    assert_eq!(s["tasks"].as_array().unwrap().len(), 10);
    assert_eq!(s["tasks"][9]["id"], "t0");
    assert!(!text.contains("not shown"), "{text}");
    let (s, text) = page(json!({"state": "runing", "limit": 5})).apply(listed(10), NOW);
    let ids: Vec<&str> =
        s["tasks"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["t9", "t7", "t5", "t3", "t1"]);
    assert!(text.ends_with("(state \"runing\" read as \"running\")"), "{text}");
    let (s, _) = page(json!({"state": "failed"})).apply(listed(8), NOW);
    let ids: Vec<&str> =
        s["tasks"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["t6", "t2"], "exit codes 2 and 2 failed; 0 is ok");
    let (s, text) = page(json!({"full": true, "limit": 1})).apply(listed(2), NOW);
    assert_eq!(s["tasks"][0]["tail"].as_str().unwrap().len(), 1024);
    assert!(text.contains(&"y".repeat(1024)));
    assert_eq!(page(json!({"limit": 9999})).limit, MAX_LIMIT);
    assert!(Page::take(&mut json!({"state": "zzzzzzzz"})).is_err());
    assert!(Page::take(&mut json!({"limit": "many"})).is_err());
    let (_, text) = page(json!({"state": "lost"})).apply(listed(3), NOW);
    assert_eq!(text, "No lost tasks.");
}

/// `status` is `state`'s near miss (as `runing` is `running`'s): it picks exactly the page
/// `state` picks, and the answer says it was read that way. It used to go to the daemon,
/// which does not read it either, so the call answered an unfiltered page.
#[test]
fn status_picks_the_page_state_picks_and_says_so() {
    let (by_status, text) = page(json!({"status": "running", "limit": 5})).apply(listed(10), NOW);
    let (by_state, _) = page(json!({"state": "running", "limit": 5})).apply(listed(10), NOW);
    assert_eq!(by_status, by_state);
    let ids: Vec<&str> =
        by_status["tasks"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["t9", "t7", "t5", "t3", "t1"]);
    assert_eq!(by_status["total"], json!(5), "the filter ran, so the page is not the whole list");
    assert!(text.ends_with("(key \"status\" read as \"state\")"), "{text}");
    // A near-miss key takes the state's own near-miss reading too, and both are said.
    let (s, text) = page(json!({"status": "runing"})).apply(listed(4), NOW);
    assert_eq!(s["total"], json!(2));
    assert!(text.contains("(key \"status\" read as \"state\")"), "{text}");
    assert!(text.contains("(state \"runing\" read as \"running\")"), "{text}");
    // A near miss is not read over a key the call already gave.
    let (s, text) = page(json!({"status": "running", "state": "failed"})).apply(listed(8), NOW);
    assert_eq!(s["total"], json!(2), "state failed stands: {text}");
}

/// A key that is nobody's near miss is named in the answer, not quietly passed on: a filter
/// the call thought it set and did not is worse than a page it knows is unfiltered.
#[test]
fn an_unknown_key_is_named_not_ignored() {
    let (s, text) = page(json!({"nonsense": "running", "limit": 2})).apply(listed(6), NOW);
    assert_eq!(s["total"], json!(6), "nothing was filtered");
    assert!(
        text.ends_with(
            "(\"nonsense\" is not one of state, limit, offset, full, all, so it picked nothing)"
        ),
        "{text}"
    );
    let mut args = json!({"nonsense": 1, "sessionId": "s", "all": true});
    let taken = Page::take(&mut args).unwrap();
    assert_eq!(
        args,
        json!({"sessionId": "s", "all": true}),
        "the daemon's keys stay, the stray one goes"
    );
    assert_eq!(taken.notes.len(), 1, "{:?}", taken.notes);
}

#[test]
fn ages_and_cuts() {
    assert_eq!(
        [age(5_000), age(120_000), age(7_200_000), age(200_000_000)],
        ["5s", "2m", "2h", "2d"]
    );
    assert_eq!(cut("a\n  b", 10), "a b");
    assert_eq!(cut("abcdefghij", 5), "abcd…");
}
