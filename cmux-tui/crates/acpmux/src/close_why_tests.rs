use super::*;
use serde_json::json;

fn meta(tags: Value) -> SessionMeta {
    let mut m: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
        "cwd": "/tmp", "createdAt": 1, "updatedAt": 1, "status": "idle",
    }))
    .unwrap();
    m.tags = serde_json::from_value(tags).unwrap();
    m
}

#[test]
fn a_lane_closed_with_no_outcome_is_unfinished() {
    let lane = meta(json!({"lane.reportsTo": {"value": "coord"}}));
    let r = CloseRecord::new(CloseWhy::by("cli", "stop"), &lane, 5);
    assert_eq!(r.outcome, "unfinished");
    let r = CloseRecord::new(CloseWhy::by("cli", "stop").outcome("done"), &lane, 5);
    assert_eq!(r.outcome, "done");
    let goal = meta(json!({"goal": {"value": "ship it"}}));
    assert_eq!(CloseRecord::new(CloseWhy::by("ttl", "x"), &goal, 5).outcome, "unfinished");
    let plain = meta(json!({}));
    assert_eq!(CloseRecord::new(CloseWhy::by("cli", "x"), &plain, 5).outcome, "dropped");
}

#[test]
fn the_record_reads_back_as_its_json() {
    let actor = CloseActor::new("mcp").session(Some("parent")).pid(Some(42));
    let why = CloseWhy::from_params(actor, &json!({"reason": " merged ", "outcome": ""}));
    let r = CloseRecord::new(why, &meta(json!({})), 7);
    let v = serde_json::to_value(&r).unwrap();
    assert_eq!(
        v,
        json!({"closedAt": 7, "actor": {"kind": "mcp", "session": "parent", "pid": 42},
               "reason": "merged", "outcome": "dropped"})
    );
    assert_eq!(serde_json::from_value::<CloseRecord>(v).unwrap(), r);
}
