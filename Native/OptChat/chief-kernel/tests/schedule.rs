//! The schedule ledger (a749's order, item 3; chief-next-DESIGN.md section 2):
//! `schedule_set {id, cron | at_ms, prompt, expires_ms?}` and
//! `schedule_removed {id}` keep a Chief's recurring and one-shot jobs in the
//! kernel state, and `check_due` fires each due one as a keyed `notice` (a
//! note that starts a turn). Cron is 5 fields in the person's UTC offset
//! (`ctx.utc_offset_minutes`). A computer that slept through several slots
//! fires once, not a burst. A recurring job expires after 7 days unless it
//! names its own expiry.

use chief_kernel::ledger::ledger_apply;
use serde_json::{Value, json};

const H: u64 = 3_600_000;
const D: u64 = 24 * H;
/// 2026-10-28T00:00:00Z.
const DAY0: u64 = 1_793_145_600_000;

struct Fold {
    state: String,
    offset: i64,
}

impl Fold {
    fn new(offset: i64) -> Self {
        Fold {
            state: "{}".into(),
            offset,
        }
    }

    fn apply(&mut self, event: Value, now: u64) -> Result<Vec<Value>, String> {
        let ctx = json!({"now_ms": now, "utc_offset_minutes": self.offset}).to_string();
        let out: Value =
            serde_json::from_str(&ledger_apply(&self.state, &event.to_string(), &ctx)?).unwrap();
        self.state = out["state"].to_string();
        Ok(out["intents"].as_array().unwrap().clone())
    }

    fn check(&mut self, now: u64) -> Vec<Value> {
        self.apply(json!({"type": "check_due"}), now).unwrap()
    }

    fn state(&self) -> Value {
        serde_json::from_str(&self.state).unwrap()
    }
}

fn fires(intents: &[Value]) -> Vec<&Value> {
    intents
        .iter()
        .filter(|i| i["kind"] == "notice" && i["key"].as_str().unwrap().starts_with("fire-"))
        .collect()
}

fn next_check(intents: &[Value]) -> Option<u64> {
    intents
        .iter()
        .filter(|i| i["kind"] == "schedule")
        .filter_map(|i| i["at_ms"].as_u64())
        .min()
}

fn daily_nine(id: &str) -> Value {
    json!({"type": "schedule_set", "id": id, "cron": "0 9 * * *", "prompt": "post the PR sweep"})
}

#[test]
fn a_cron_job_fires_at_its_slot_as_a_keyed_notice_and_asks_for_the_next() {
    let mut f = Fold::new(0);
    let set = f.apply(daily_nine("s1"), DAY0 + 8 * H).unwrap();
    assert_eq!(next_check(&set), Some(DAY0 + 9 * H), "{set:?}");
    assert!(fires(&f.check(DAY0 + 8 * H + 1)).is_empty(), "not yet");
    let at_nine = f.check(DAY0 + 9 * H);
    let fired = fires(&at_nine);
    assert_eq!(fired.len(), 1, "{at_nine:?}");
    assert_eq!(fired[0]["key"], format!("fire-s1-{}", DAY0 + 9 * H));
    assert!(
        fired[0]["text"]
            .as_str()
            .unwrap()
            .contains("post the PR sweep")
    );
    assert!(
        fired[0]["text"]
            .as_str()
            .unwrap()
            .starts_with("[schedule s1]")
    );
    assert_eq!(next_check(&at_nine), Some(DAY0 + D + 9 * H));
}

#[test]
fn cron_reads_the_persons_clock() {
    // 09:00 in UTC-7 is 16:00 UTC.
    let mut f = Fold::new(-420);
    let set = f.apply(daily_nine("s1"), DAY0).unwrap();
    assert_eq!(next_check(&set), Some(DAY0 + 16 * H));
}

#[test]
fn a_computer_that_slept_through_slots_fires_once_not_a_burst() {
    let mut f = Fold::new(0);
    f.apply(daily_nine("s1"), DAY0 + 8 * H).unwrap();
    let woke = f.check(DAY0 + 3 * D + 10 * H);
    let fired = fires(&woke);
    assert_eq!(fired.len(), 1, "one catch-up firing: {woke:?}");
    assert_eq!(
        fired[0]["key"],
        format!("fire-s1-{}", DAY0 + 3 * D + 9 * H),
        "keyed by the latest slot it missed"
    );
    assert_eq!(next_check(&woke), Some(DAY0 + 4 * D + 9 * H));
    assert!(
        fires(&f.check(DAY0 + 3 * D + 10 * H)).is_empty(),
        "a replayed check fires nothing more"
    );
}

#[test]
fn a_one_shot_job_fires_once_and_is_gone() {
    let mut f = Fold::new(0);
    let at = DAY0 + 2 * H;
    f.apply(
        json!({"type": "schedule_set", "id": "w1", "at_ms": at, "prompt": "check the deploy"}),
        DAY0,
    )
    .unwrap();
    assert_eq!(fires(&f.check(at)).len(), 1);
    assert!(fires(&f.check(at + D)).is_empty());
    assert!(
        f.state()["schedules"]
            .as_array()
            .is_none_or(|s| s.is_empty())
    );
}

#[test]
fn a_removed_job_never_fires() {
    let mut f = Fold::new(0);
    f.apply(daily_nine("s1"), DAY0).unwrap();
    f.apply(json!({"type": "schedule_removed", "id": "s1"}), DAY0 + H)
        .unwrap();
    assert!(fires(&f.check(DAY0 + 9 * H)).is_empty());
}

#[test]
fn setting_the_same_id_again_replaces_the_job() {
    let mut f = Fold::new(0);
    f.apply(daily_nine("s1"), DAY0).unwrap();
    let set = f
        .apply(
            json!({"type": "schedule_set", "id": "s1", "cron": "30 18 * * *", "prompt": "evening digest"}),
            DAY0,
        )
        .unwrap();
    assert_eq!(next_check(&set), Some(DAY0 + 18 * H + 30 * 60_000));
    assert_eq!(f.state()["schedules"].as_array().unwrap().len(), 1);
}

#[test]
fn a_recurring_job_expires_after_seven_days_with_one_note() {
    let mut f = Fold::new(0);
    f.apply(daily_nine("s1"), DAY0 + 8 * H).unwrap();
    for day in 0..7 {
        assert_eq!(
            fires(&f.check(DAY0 + day * D + 9 * H)).len(),
            1,
            "day {day}"
        );
    }
    let late = f.check(DAY0 + 8 * D + 9 * H);
    assert!(fires(&late).is_empty(), "expired: {late:?}");
    let notes: Vec<&Value> = late.iter().filter(|i| i["kind"] == "notice").collect();
    assert_eq!(notes.len(), 1, "one expiry note: {late:?}");
    assert!(notes[0]["text"].as_str().unwrap().contains("expired"));
    assert!(
        f.state()["schedules"]
            .as_array()
            .is_none_or(|s| s.is_empty())
    );
}

#[test]
fn a_running_turn_defers_the_firing() {
    let mut f = Fold::new(0);
    f.apply(daily_nine("s1"), DAY0).unwrap();
    f.apply(json!({"type": "turn_started"}), DAY0 + 9 * H - 1)
        .unwrap();
    let busy = f.check(DAY0 + 9 * H);
    assert!(fires(&busy).is_empty());
    assert!(next_check(&busy).is_some_and(|t| t > DAY0 + 9 * H));
    f.apply(json!({"type": "turn_ended"}), DAY0 + 9 * H + 1_000)
        .unwrap();
    assert_eq!(fires(&f.check(DAY0 + 9 * H + 6_000)).len(), 1);
}

#[test]
fn weekdays_ranges_and_steps() {
    // 2026-10-28 is a Wednesday. "*/15 9-10 * * 1-5" after Wed 10:50: the
    // last slot, 10:45, has passed, so the next is Thu 09:00.
    let mut f = Fold::new(0);
    let set = f
        .apply(
            json!({"type": "schedule_set", "id": "s1", "cron": "*/15 9-10 * * 1-5", "prompt": "x"}),
            DAY0 + 10 * H + 50 * 60_000,
        )
        .unwrap();
    assert_eq!(next_check(&set), Some(DAY0 + D + 9 * H));
    // Saturday 2026-10-31 -> Monday 2026-11-02 09:00.
    let mut f = Fold::new(0);
    let set = f
        .apply(
            json!({"type": "schedule_set", "id": "s1", "cron": "0 9 * * mon-fri", "prompt": "x"}),
            DAY0 + 3 * D + 12 * H,
        )
        .unwrap();
    assert_eq!(next_check(&set), Some(DAY0 + 5 * D + 9 * H));
}

#[test]
fn a_bad_or_impossible_job_is_an_error() {
    for cron in ["0 9 * *", "61 * * * *", "0 9 30 2 *", "every morning"] {
        let mut f = Fold::new(0);
        let e = json!({"type": "schedule_set", "id": "s1", "cron": cron, "prompt": "x"});
        assert!(f.apply(e, DAY0).is_err(), "{cron} accepted");
    }
    let mut f = Fold::new(0);
    assert!(
        f.apply(
            json!({"type": "schedule_set", "id": "s1", "prompt": "x"}),
            DAY0
        )
        .is_err(),
        "neither cron nor at_ms"
    );
}
