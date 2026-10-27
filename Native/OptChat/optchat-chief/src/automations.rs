//! The local Chief's automations (issue 25573): a task the person asked the
//! Chief to do on a schedule or when an event happens, kept in the host
//! state (`HostState::automations`) so it outlives restarts, and shown in
//! Home's Chief settings, where the person pauses, resumes and deletes it
//! (`chief.automation.list` / `chief.automation.update`).
//!
//! Each fire queues the Chief's own note `[automation <id> "<name>"]
//! <prompt>` (brain/automations.rs), which starts a normal turn whose reply
//! posts in the Chief conversation, as a `sleep` wake does.
//!
//! Triggers:
//!
//! - `schedule`: a five-field cron (`0 9 * * *`, `@daily`) in this Mac's
//!   time zone. A fire missed while the host was down runs once, late, at
//!   the next start; never once per missed slot.
//! - `agent_done`: one of this Chief's subagents finished a run (its report
//!   reached the Chief), optionally only when its title contains `match`.
//!
//! Both come to the brain as they happen; nothing here polls. An event that
//! happens elsewhere (CI failed, a pull request opened) is pushed to the
//! Cloud Chief by its provider's webhook, so those jobs are the Cloud
//! Chief's (`chief-auto`), never a poll of GitHub from this Mac.
//!
//! An event fires an automation once: each automation keeps the keys of the
//! events it fired for (a subagent run), so a repeated report never fires
//! it again.
//!
//! A subagent another person's turn started never fires `agent_done` (its
//! report reaches the Chief under the ask floor; a note would not), nor one
//! an automation's own turn started (it would fire itself again).
//!
//! This is the Mac's own scheduler: it runs while this Chief's host runs.
//! A job that must run on time while the computer sleeps belongs to the Cloud Chief
//! (`chief-auto`, plans/cmux-next/chief-automations-DESIGN.md).

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveTime, TimeZone};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};

/// Most automations one Chief keeps.
pub const AUTOMATIONS_MAX: usize = 20;
/// Event keys each automation remembers (oldest dropped first).
pub const FIRED_KEPT: usize = 64;
/// Longest automation name.
pub const NAME_MAX: usize = 80;
/// Longest automation prompt.
pub const PROMPT_MAX: usize = 4000;
/// The `automation` tool's actions.
pub const ACTIONS: [&str; 6] = ["add", "list", "pause", "resume", "delete", "run"];
/// The events an automation can wait for.
pub const EVENTS: [&str; 1] = ["agent_done"];

/// What starts an automation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Trigger {
    /// A five-field cron in this Mac's time zone.
    Schedule { cron: String },
    /// One of this Chief's subagents finished a run; `matches`: only when
    /// its title contains this text (any case).
    AgentDone {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        matches: Option<String>,
    },
}

impl Trigger {
    /// One line for the person: `every day at 09:00 (cron 0 9 * * *)`.
    pub fn describe(&self) -> String {
        match self {
            Trigger::Schedule { cron } => format!("on the schedule `{cron}`"),
            Trigger::AgentDone { matches: None } => "when a subagent finishes".to_owned(),
            Trigger::AgentDone { matches: Some(m) } => {
                format!("when a subagent whose title has \"{m}\" finishes")
            }
        }
    }

    /// The trigger's kind as the tool and the app name it.
    pub fn kind(&self) -> &'static str {
        match self {
            Trigger::Schedule { .. } => "schedule",
            Trigger::AgentDone { .. } => "agent_done",
        }
    }
}

/// One automation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Automation {
    /// `au<N>`, unique for this Chief home.
    pub id: String,
    pub name: String,
    /// What the Chief does at each fire, in the person's words.
    pub prompt: String,
    pub trigger: Trigger,
    /// Paused in the app or by the Chief: never fires until resumed.
    #[serde(default)]
    pub paused: bool,
    /// When it was made (ms since the epoch).
    pub created_ms: u64,
    /// `schedule`: the next fire (ms since the epoch); None while paused or
    /// when the cron never matches again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_ms: Option<u64>,
    /// The last fire (ms since the epoch).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_fired_ms: Option<u64>,
    /// How many times it fired.
    #[serde(default)]
    pub runs: u64,
    /// The keys of the events it fired for, newest last (at most
    /// [`FIRED_KEPT`]).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fired: Vec<String>,
}

impl Automation {
    /// Whether it already fired for event `key`.
    pub fn fired_for(&self, key: &str) -> bool {
        self.fired.iter().any(|k| k == key)
    }

    /// Records a fire at `now_ms` (for event `key` when given).
    pub fn record_fire(&mut self, now_ms: u64, key: Option<&str>) {
        self.runs += 1;
        self.last_fired_ms = Some(now_ms);
        if let Some(key) = key
            && !self.fired_for(key)
        {
            self.fired.push(key.to_owned());
            let extra = self.fired.len().saturating_sub(FIRED_KEPT);
            self.fired.drain(..extra);
        }
    }

    /// The record as the app and `list` read it.
    pub fn to_json(&self) -> Value {
        let mut trigger = serde_json::to_value(&self.trigger).unwrap_or(Value::Null);
        trigger["summary"] = json!(self.trigger.describe());
        json!({
            "id": self.id,
            "name": self.name,
            "prompt": self.prompt,
            "trigger": trigger,
            "paused": self.paused,
            "created_ms": self.created_ms,
            "next_ms": self.next_ms,
            "last_fired_ms": self.last_fired_ms,
            "runs": self.runs,
        })
    }

    /// One line of `list`.
    pub fn line(&self) -> String {
        let state = if self.paused { "paused" } else { "active" };
        let next = match self.next_ms {
            Some(ms) => format!(", next {}", local_time(ms)),
            None => String::new(),
        };
        format!(
            "{} \"{}\" ({state}) {}{next}, fired {} time(s): {}",
            self.id,
            self.name,
            self.trigger.describe(),
            self.runs,
            clip(&self.prompt, 160)
        )
    }

    /// The note a fire queues: the Chief's own words, not the person's now.
    pub fn note(&self, why: &str) -> String {
        format!(
            "[automation {} \"{}\"] {}\n(Your automation {}, made when the person asked for it; it fired {why}. Do it now and post the result in this chat. It is not a new message from the person; `automation` lists, pauses and deletes it.)",
            self.id,
            self.name,
            self.prompt,
            self.trigger.describe(),
        )
    }
}

/// The saved automations, skipping one this build cannot read (a trigger a
/// newer or older build made) so the rest of the host state still loads.
pub fn deserialize_kept<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<Automation>, D::Error> {
    let saved = Vec::<Value>::deserialize(d)?;
    Ok(saved
        .into_iter()
        .filter_map(|v| match serde_json::from_value::<Automation>(v) {
            Ok(a) => Some(a),
            Err(e) => {
                crate::log::log(format!("an automation is unreadable ({e}); it is dropped"));
                None
            }
        })
        .collect())
}

/// `ms` as this Mac's local time, `2026-10-26 09:00`.
pub fn local_time(ms: u64) -> String {
    chrono::Local
        .timestamp_millis_opt(ms as i64)
        .single()
        .map(|t| t.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_else(|| ms.to_string())
}

fn clip(text: &str, max: usize) -> String {
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        return one_line;
    }
    let mut out: String = one_line.chars().take(max).collect();
    out.push('…');
    out
}

// ------------------------------------------------------------------ cron

/// A parsed five-field cron: minute, hour, day of month, month, day of week.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cron {
    minutes: u64,
    hours: u32,
    days: u32,
    months: u16,
    weekdays: u8,
    /// Day of month and day of week both restricted: either matches (as
    /// every cron does).
    either_day: bool,
}

const MONTHS: [&str; 12] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];
const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

impl Cron {
    /// Parses `0 9 * * 1-5`, `*/15 * * * *`, `30 8 1 jan,jul *` or one of
    /// `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`.
    pub fn parse(text: &str) -> Result<Cron, String> {
        let text = text.trim();
        let expanded = match text {
            "@hourly" => "0 * * * *",
            "@daily" | "@midnight" => "0 0 * * *",
            "@weekly" => "0 0 * * 0",
            "@monthly" => "0 0 1 * *",
            "@yearly" | "@annually" => "0 0 1 1 *",
            other => other,
        };
        let fields: Vec<&str> = expanded.split_whitespace().collect();
        let [minute, hour, day, month, weekday] = fields[..] else {
            return Err(format!(
                "cron `{text}`: five fields (minute hour day-of-month month day-of-week), like `0 9 * * 1-5`"
            ));
        };
        let minutes = field(minute, 0, 59, &[])?;
        let hours = field(hour, 0, 23, &[])? as u32;
        let days = field(day, 1, 31, &[])? as u32;
        let months = field(month, 1, 12, &MONTHS)? as u16;
        // 7 is Sunday too.
        let mut weekdays = field(weekday, 0, 7, &WEEKDAYS)?;
        if weekdays & (1 << 7) != 0 {
            weekdays |= 1;
        }
        let weekdays = (weekdays & 0x7f) as u8;
        Ok(Cron {
            minutes,
            hours,
            days,
            months,
            weekdays,
            either_day: !day.starts_with('*') && !weekday.starts_with('*'),
        })
    }

    fn day_matches(&self, date: NaiveDate) -> bool {
        if self.months & (1 << date.month()) == 0 {
            return false;
        }
        let dom = self.days & (1 << date.day()) != 0;
        let dow = self.weekdays & (1 << date.weekday().num_days_from_sunday()) != 0;
        if self.either_day {
            dom || dow
        } else {
            dom && dow
        }
    }

    /// The first time strictly after `after` that the cron names, in
    /// `after`'s time zone. A local time a DST change skips is skipped; one
    /// it repeats fires at its first occurrence. None when no day in the
    /// next five years matches (`0 0 30 2 *`).
    pub fn next_after<Tz: TimeZone>(&self, after: &DateTime<Tz>) -> Option<DateTime<Tz>> {
        let tz = after.timezone();
        let local = after.naive_local();
        let start_day = local.date();
        for offset in 0..(366 * 5) {
            let date = start_day + Duration::days(offset);
            if !self.day_matches(date) {
                continue;
            }
            for hour in 0..24u32 {
                if self.hours & (1 << hour) == 0 {
                    continue;
                }
                for minute in 0..60u32 {
                    if self.minutes & (1 << minute) == 0 {
                        continue;
                    }
                    let Some(time) = NaiveTime::from_hms_opt(hour, minute, 0) else {
                        continue;
                    };
                    let naive = date.and_time(time);
                    if offset == 0 && naive <= local {
                        continue;
                    }
                    if let Some(at) = tz.from_local_datetime(&naive).earliest()
                        && at > *after
                    {
                        return Some(at);
                    }
                }
            }
        }
        None
    }

    /// [`Cron::next_after`] in this Mac's time zone, in ms since the epoch.
    pub fn next_local_ms(&self, after_ms: u64) -> Option<u64> {
        let after = chrono::Local
            .timestamp_millis_opt(after_ms as i64)
            .single()?;
        self.next_after(&after).map(|t| t.timestamp_millis() as u64)
    }
}

/// One cron field as a bit set (bit `n` set: value `n` matches). `names`
/// name the values from `min` up (months from 1, weekdays from 0).
fn field(text: &str, min: u32, max: u32, names: &[&str]) -> Result<u64, String> {
    let value = |word: &str| -> Result<u32, String> {
        let lower = word.to_ascii_lowercase();
        if let Some(i) = names.iter().position(|n| *n == lower) {
            return Ok(i as u32 + min);
        }
        word.parse::<u32>()
            .map_err(|_| format!("cron: `{word}` is not a number"))
    };
    let mut bits = 0u64;
    for part in text.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => (
                r,
                s.parse::<u32>()
                    .ok()
                    .filter(|s| *s > 0)
                    .ok_or_else(|| format!("cron: bad step in `{part}`"))?,
            ),
            None => (part, 1),
        };
        let (lo, hi) = if range == "*" {
            (min, max)
        } else if let Some((a, b)) = range.split_once('-') {
            (value(a)?, value(b)?)
        } else {
            let v = value(range)?;
            // `5/15` runs from 5 to the end, as in every cron.
            (v, if step > 1 { max } else { v })
        };
        if lo < min || hi > max || lo > hi || step > max {
            return Err(format!("cron: `{part}` is outside {min}-{max}"));
        }
        let mut v = lo;
        while v <= hi {
            bits |= 1 << v;
            v += step;
        }
    }
    if bits == 0 {
        return Err(format!("cron: `{text}` names no value"));
    }
    Ok(bits)
}

// ------------------------------------------------------------------ the tool

/// One `automation` call.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AutomationCall {
    pub action: String,
    /// pause, resume, delete, run: the automation (`au<N>`).
    pub id: Option<String>,
    /// add: its name.
    pub name: Option<String>,
    /// add: what the Chief does at each fire.
    pub prompt: Option<String>,
    /// add: a five-field cron (a schedule).
    pub cron: Option<String>,
    /// add: `agent_done` (an event).
    pub event: Option<String>,
    /// add, `agent_done`: only subagents whose title has this.
    pub matches: Option<String>,
}

impl AutomationCall {
    pub fn parse(args: &Value) -> Result<AutomationCall, String> {
        let text = |key: &str| {
            args.get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(str::to_owned)
        };
        let action = text("action").unwrap_or_else(|| "list".to_owned());
        if !ACTIONS.contains(&action.as_str()) {
            return Err(format!(
                "automation: no action {action}; one of {}",
                ACTIONS.join(", ")
            ));
        }
        let call = AutomationCall {
            action,
            id: text("id"),
            name: text("name"),
            prompt: text("prompt"),
            cron: text("cron"),
            event: text("event"),
            matches: text("match"),
        };
        if !matches!(call.action.as_str(), "add" | "list") && call.id.is_none() {
            return Err(format!("automation {}: `id` is required", call.action));
        }
        if call.action == "add" {
            call.trigger()?;
            call.texts()?;
        }
        Ok(call)
    }

    /// add: the name and prompt, checked.
    pub fn texts(&self) -> Result<(String, String), String> {
        let prompt = self
            .prompt
            .clone()
            .ok_or("automation add: `prompt` is required (what to do at each fire)")?;
        if prompt.chars().count() > PROMPT_MAX {
            return Err(format!(
                "automation add: `prompt` is at most {PROMPT_MAX} characters"
            ));
        }
        let name = self.name.clone().unwrap_or_else(|| clip(&prompt, 40));
        if name.chars().count() > NAME_MAX {
            return Err(format!(
                "automation add: `name` is at most {NAME_MAX} characters"
            ));
        }
        Ok((name, prompt))
    }

    /// add: the trigger, checked.
    pub fn trigger(&self) -> Result<Trigger, String> {
        match (&self.cron, self.event.as_deref()) {
            (Some(_), Some(_)) => Err("automation add: give `cron` or `event`, not both".into()),
            (None, None) => {
                Err("automation add: give `cron` (like `0 9 * * *`) or `event` (agent_done)".into())
            }
            (Some(cron), None) => {
                Cron::parse(cron)?;
                Ok(Trigger::Schedule { cron: cron.clone() })
            }
            (None, Some("agent_done")) => Ok(Trigger::AgentDone {
                matches: self.matches.clone(),
            }),
            (None, Some(other)) => Err(format!(
                "automation add: no event {other}; one of {}",
                EVENTS.join(", ")
            )),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut v = json!({"tool": "automation", "action": self.action});
        for (key, value) in [
            ("id", &self.id),
            ("name", &self.name),
            ("prompt", &self.prompt),
            ("cron", &self.cron),
            ("event", &self.event),
            ("match", &self.matches),
        ] {
            if let Some(value) = value {
                v[key] = json!(value);
            }
        }
        v
    }
}

// ------------------------------------------------------------------ events

/// Something that happened that an event automation may fire for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// Subagent `id` (`title`) finished a run that started at `run_ms`.
    AgentDone {
        id: String,
        title: String,
        run_ms: u64,
        report: String,
    },
}

impl Event {
    /// The key an automation remembers so it fires once for this event.
    pub fn key(&self) -> String {
        match self {
            Event::AgentDone { id, run_ms, .. } => format!("agent:{id}:{run_ms}"),
        }
    }

    /// Whether `automation` fires for this event (paused ones never do).
    pub fn fires(&self, automation: &Automation) -> bool {
        if automation.paused || automation.fired_for(&self.key()) {
            return false;
        }
        match (&automation.trigger, self) {
            (Trigger::AgentDone { matches }, Event::AgentDone { title, .. }) => matches
                .as_deref()
                .is_none_or(|m| title.to_lowercase().contains(&m.to_lowercase())),
            _ => false,
        }
    }

    /// How the note says why it fired.
    pub fn why(&self) -> String {
        match self {
            Event::AgentDone {
                id, title, report, ..
            } => format!(
                "because subagent {id} \"{title}\" finished; its report: {}",
                clip(report, 600)
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{FixedOffset, Utc};

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn every_morning_at_nine_is_the_next_nine() {
        let cron = Cron::parse("0 9 * * *").unwrap();
        assert_eq!(
            cron.next_after(&at("2026-10-26T08:30:00Z")),
            Some(at("2026-10-26T09:00:00Z"))
        );
        // At 9:00 itself the next one is tomorrow's: never twice a minute.
        assert_eq!(
            cron.next_after(&at("2026-10-26T09:00:00Z")),
            Some(at("2026-10-27T09:00:00Z"))
        );
        assert_eq!(
            cron.next_after(&at("2026-10-26T09:00:30Z")),
            Some(at("2026-10-27T09:00:00Z"))
        );
    }

    #[test]
    fn weekdays_skip_the_weekend() {
        let cron = Cron::parse("0 9 * * 1-5").unwrap();
        // 2026-10-30 is a Friday.
        assert_eq!(
            cron.next_after(&at("2026-10-30T10:00:00Z")),
            Some(at("2026-11-02T09:00:00Z"))
        );
        let names = Cron::parse("0 9 * * mon-fri").unwrap();
        assert_eq!(names, cron);
    }

    #[test]
    fn steps_lists_and_aliases() {
        let every15 = Cron::parse("*/15 * * * *").unwrap();
        assert_eq!(
            every15.next_after(&at("2026-10-26T08:16:00Z")),
            Some(at("2026-10-26T08:30:00Z"))
        );
        let list = Cron::parse("0 8,17 * * *").unwrap();
        assert_eq!(
            list.next_after(&at("2026-10-26T09:00:00Z")),
            Some(at("2026-10-26T17:00:00Z"))
        );
        assert_eq!(
            Cron::parse("@daily").unwrap(),
            Cron::parse("0 0 * * *").unwrap()
        );
        let jan = Cron::parse("0 0 1 jan *").unwrap();
        assert_eq!(
            jan.next_after(&at("2026-10-26T00:00:00Z")),
            Some(at("2027-01-01T00:00:00Z"))
        );
        // Sunday as 7.
        assert_eq!(
            Cron::parse("0 0 * * 7").unwrap(),
            Cron::parse("0 0 * * 0").unwrap()
        );
    }

    #[test]
    fn day_of_month_or_day_of_week() {
        // The 1st, or any Monday.
        let cron = Cron::parse("0 9 1 * mon").unwrap();
        // 2026-10-27 is a Tuesday; the next Monday is 11-02, after the 1st.
        assert_eq!(
            cron.next_after(&at("2026-10-27T10:00:00Z")),
            Some(at("2026-11-01T09:00:00Z"))
        );
    }

    #[test]
    fn a_cron_in_a_time_zone() {
        let pacific = FixedOffset::west_opt(7 * 3600).unwrap();
        let after = pacific.with_ymd_and_hms(2026, 10, 26, 8, 0, 0).unwrap();
        let next = Cron::parse("0 9 * * *")
            .unwrap()
            .next_after(&after)
            .unwrap();
        assert_eq!(
            next,
            pacific.with_ymd_and_hms(2026, 10, 26, 9, 0, 0).unwrap()
        );
        assert_eq!(next.with_timezone(&Utc), at("2026-10-26T16:00:00Z"));
    }

    #[test]
    fn bad_crons_say_why() {
        for bad in [
            "",
            "0 9 * *",
            "61 * * * *",
            "0 25 * * *",
            "*/0 * * * *",
            "0 9 * * fun",
            "5-1 * * * *",
        ] {
            assert!(Cron::parse(bad).is_err(), "{bad:?} parsed");
        }
        // February 30th never comes.
        assert_eq!(
            Cron::parse("0 0 30 2 *")
                .unwrap()
                .next_after(&at("2026-01-01T00:00:00Z")),
            None
        );
    }

    fn automation(trigger: Trigger) -> Automation {
        Automation {
            id: "au1".into(),
            name: "n".into(),
            prompt: "p".into(),
            trigger,
            paused: false,
            created_ms: 1_000,
            next_ms: None,
            last_fired_ms: None,
            runs: 0,
            fired: Vec::new(),
        }
    }

    #[test]
    fn huge_cron_steps_are_refused() {
        assert!(Cron::parse("1/4294967295 * * * *").is_err());
        assert!(Cron::parse("*/60 * * * *").is_err());
        assert!(Cron::parse("*/59 * * * *").is_ok());
    }

    #[test]
    fn agent_done_fires_once_per_run_and_matches_titles() {
        let done = |id: &str, title: &str, run_ms| Event::AgentDone {
            id: id.into(),
            title: title.into(),
            run_ms,
            report: "landed".into(),
        };
        let mut any = automation(Trigger::AgentDone { matches: None });
        assert!(done("a1", "Fix CI", 10).fires(&any));
        any.record_fire(11, Some(&done("a1", "Fix CI", 10).key()));
        assert!(!done("a1", "Fix CI", 10).fires(&any));
        assert!(done("a1", "Fix CI", 20).fires(&any), "its next run");
        let only = automation(Trigger::AgentDone {
            matches: Some("ci".into()),
        });
        assert!(done("a2", "Fix CI", 10).fires(&only));
        assert!(!done("a3", "Docs", 10).fires(&only));
    }

    #[test]
    fn fired_keys_are_bounded() {
        let mut a = automation(Trigger::AgentDone { matches: None });
        for n in 0..(FIRED_KEPT as u64 + 5) {
            a.record_fire(n, Some(&format!("k{n}")));
        }
        assert_eq!(a.fired.len(), FIRED_KEPT);
        assert_eq!(a.runs, FIRED_KEPT as u64 + 5);
        assert!(!a.fired_for("k0"));
    }

    #[test]
    fn the_tool_checks_its_arguments() {
        let parse = |v: Value| AutomationCall::parse(&v);
        let add = parse(json!({"action": "add", "name": "PRs", "prompt": "summarize my open PRs", "cron": "0 9 * * *"})).unwrap();
        assert_eq!(
            add.trigger().unwrap(),
            Trigger::Schedule {
                cron: "0 9 * * *".into()
            }
        );
        assert!(
            parse(json!({"action": "add", "prompt": "x"})).is_err(),
            "no trigger"
        );
        assert!(parse(json!({"action": "add", "prompt": "x", "cron": "nope"})).is_err());
        assert!(
            parse(json!({"action": "add", "prompt": "x", "event": "ci_red", "repo": "a/b"}))
                .is_err(),
            "a GitHub event is the Cloud Chief's, never a poll from this Mac"
        );
        assert!(parse(json!({"action": "add", "prompt": "x", "event": "nope"})).is_err());
        assert!(
            parse(json!({"action": "add", "cron": "@daily"})).is_err(),
            "no prompt"
        );
        assert!(parse(json!({"action": "pause"})).is_err(), "no id");
        assert!(parse(json!({"action": "explode"})).is_err());
        assert_eq!(parse(json!({})).unwrap().action, "list");
        let done = parse(
            json!({"action": "add", "prompt": "review it", "event": "agent_done", "match": "fix"}),
        )
        .unwrap();
        assert_eq!(
            done.trigger().unwrap(),
            Trigger::AgentDone {
                matches: Some("fix".into())
            }
        );
        assert_eq!(
            done.texts().unwrap().0,
            "review it",
            "the name defaults to the prompt"
        );
        assert_eq!(AutomationCall::parse(&done.to_json()).unwrap(), done);
    }

    #[test]
    fn an_automation_this_build_cannot_read_is_dropped_alone() {
        #[derive(Deserialize)]
        struct Saved {
            #[serde(deserialize_with = "deserialize_kept")]
            automations: Vec<Automation>,
        }
        let saved: Saved = serde_json::from_value(json!({"automations": [
            {"id": "au1", "name": "CI", "prompt": "fix it", "created_ms": 1,
             "trigger": {"type": "ci_red", "repo": "o/r"}},
            {"id": "au2", "name": "Review", "prompt": "review it", "created_ms": 1,
             "trigger": {"type": "agent_done"}},
        ]}))
        .unwrap();
        assert_eq!(
            saved
                .automations
                .iter()
                .map(|a| a.id.as_str())
                .collect::<Vec<_>>(),
            ["au2"]
        );
    }
}
