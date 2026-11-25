//! Self-paced check-ins (building-always-on-agents: timers, explicit
//! outcomes, "start quiet"): at the person's check-in hours the host wakes
//! the Chief, but only when it has open loops (memory_files.rs `loops/`),
//! with a `[check-in]` note that lists them and asks for one outcome per
//! loop: act (tell its agent, start the work), send the person one short
//! line only when they must know or decide, or nothing (stop). A Chief with
//! no open loop is never woken, so a quiet day costs nothing.
//!
//! The modes are recursive's (`packages/agent/src/chief-wake.ts`
//! CHECK_IN_MODES): `auto` (weekdays 09:30, 13:30 and 16:30), `mornings`
//! (every day 09:00), `off`. Setting: `OPTCHAT_CHECK_INS`, default auto
//! (owner, 2026-11-16: self-wake on for every Chief by default).

use chrono::{Datelike, Timelike};
use serde::{Deserialize, Serialize};

/// The check-in modes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Auto,
    Mornings,
    Off,
}

impl Mode {
    pub fn parse(text: Option<&str>) -> Mode {
        match text.map(|t| t.trim().to_ascii_lowercase()).as_deref() {
            Some("off" | "0" | "false" | "no") => Mode::Off,
            Some("mornings") => Mode::Mornings,
            _ => Mode::Auto,
        }
    }

    /// The (hour, minute) slots of `day` in local time.
    fn slots(self, weekday: chrono::Weekday) -> &'static [(u32, u32)] {
        match self {
            Mode::Off => &[],
            Mode::Mornings => &[(9, 0)],
            Mode::Auto if matches!(weekday, chrono::Weekday::Sat | chrono::Weekday::Sun) => &[],
            Mode::Auto => &[(9, 30), (13, 30), (16, 30)],
        }
    }
}

/// How late a missed slot is still taken (the Mac slept, the host was off).
pub const LATE_MINUTES: u32 = 120;

/// The latest slot at or before `now` and at most `LATE_MINUTES` before it
/// (its key `YYYY-MM-DD HH:MM`): a slot missed longer is skipped (the
/// article: skip missed slots by default), so a late start never wakes the
/// Chief at night.
pub fn current_slot(mode: Mode, now: chrono::DateTime<chrono::FixedOffset>) -> Option<String> {
    let minutes = now.hour() * 60 + now.minute();
    mode.slots(now.weekday())
        .iter()
        .rev()
        .find(|(h, m)| h * 60 + m <= minutes)
        .filter(|(h, m)| minutes - (h * 60 + m) <= LATE_MINUTES)
        .map(|(h, m)| format!("{} {h:02}:{m:02}", now.format("%Y-%m-%d")))
}

/// The next slot after `now`, as local time (within 8 days).
pub fn next_slot(
    mode: Mode,
    now: chrono::DateTime<chrono::FixedOffset>,
) -> Option<chrono::DateTime<chrono::FixedOffset>> {
    for d in 0..8 {
        let day = now.date_naive() + chrono::TimeDelta::days(d);
        for (h, m) in mode.slots(day.weekday()) {
            let at = day.and_hms_opt(*h, *m, 0)?;
            let at = at.and_local_timezone(*now.offset()).single()?;
            if at > now {
                return Some(at);
            }
        }
    }
    None
}

/// The check-in note for `loops` (index lines, `memory_files::index_line`,
/// which mark a loop another person's turn wrote as data).
pub fn note(loops: &[String], slot: &str) -> String {
    let list: Vec<&str> = loops.iter().map(String::as_str).collect();
    format!(
        "[check-in] Your scheduled check-in ({slot}). Open loops:\n{}\nFor each loop: memory_read it if you need its details, then act on what is due or stale (tell its agent, start the work, set a wake for later), and forget the loops that are done. Send your person one short line only when they must know something new or decide something now; never repeat what you already told them. End with exactly one outcome: send (or reply) when they must know something, ask(question) when they must decide, or nothing(reason) when nothing needs saying (nothing is posted).",
        list.join("\n")
    )
}

/// What the person set for the Chief's own wakes (`check_ins` tool), in the
/// Chief's memory store. Every field absent: the defaults (mode from
/// `OPTCHAT_CHECK_INS`, no quiet hours, no cost limit).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WakeSettings {
    pub mode: Option<Mode>,
    /// Quiet hours, local `HH:MM-HH:MM` (may cross midnight).
    pub quiet: Option<String>,
    /// Most dollars one wake run may cost; None or 0: no limit.
    pub cost_limit_usd: Option<f64>,
}

impl WakeSettings {
    /// The cost limit in force (a positive number).
    pub fn limit(&self) -> Option<f64> {
        self.cost_limit_usd.filter(|l| *l > 0.0)
    }

    /// One line for the person and the Chief.
    pub fn describe(&self, default_mode: Mode) -> String {
        let mode = match self.mode.unwrap_or(default_mode) {
            Mode::Auto => "auto (weekdays 09:30, 13:30, 16:30, only with open loops)",
            Mode::Mornings => "mornings (09:00 every day, only with open loops)",
            Mode::Off => "off",
        };
        format!(
            "check-ins: {mode}; quiet hours: {}; cost limit per wake run: {}",
            self.quiet.as_deref().unwrap_or("none"),
            self.limit()
                .map_or("none".to_owned(), |l| format!("${l:.2}"))
        )
    }
}

/// `HH:MM-HH:MM` as minutes of the day (start, end); None when malformed.
pub fn parse_quiet(text: &str) -> Option<(u32, u32)> {
    let (a, b) = text.trim().split_once('-')?;
    let min = |t: &str| -> Option<u32> {
        let (h, m) = t.trim().split_once(':')?;
        let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
        (h < 24 && m < 60).then_some(h * 60 + m)
    };
    let (a, b) = (min(a)?, min(b)?);
    (a != b).then_some((a, b))
}

/// Whether local time `t` is inside quiet hours `quiet`.
pub fn in_quiet(quiet: Option<&str>, t: chrono::DateTime<chrono::FixedOffset>) -> bool {
    let Some((a, b)) = quiet.and_then(parse_quiet) else {
        return false;
    };
    let m = t.hour() * 60 + t.minute();
    if a < b {
        (a..b).contains(&m)
    } else {
        m >= a || m < b
    }
}

/// `t`, or the end of the quiet hours it falls in.
pub fn after_quiet(
    quiet: Option<&str>,
    t: chrono::DateTime<chrono::FixedOffset>,
) -> chrono::DateTime<chrono::FixedOffset> {
    let Some((_, b)) = quiet.and_then(parse_quiet) else {
        return t;
    };
    if !in_quiet(quiet, t) {
        return t;
    }
    let end_today = t
        .date_naive()
        .and_hms_opt(b / 60, b % 60, 0)
        .and_then(|n| n.and_local_timezone(*t.offset()).single())
        .unwrap_or(t);
    if end_today > t {
        end_today
    } else {
        end_today + chrono::TimeDelta::days(1)
    }
}

/// The longest a follow-up may wait.
pub const FOLLOW_UP_MAX_DAYS: i64 = 366;

/// When a follow-up is due: `at` (local `YYYY-MM-DDTHH:MM`, read in this
/// Mac's zone on that date, so a daylight-saving change is right, or RFC
/// 3339 with an offset) or `in` (`30m`, `2h`, `1d`), from local time `now`;
/// at most `FOLLOW_UP_MAX_DAYS` ahead.
pub fn follow_up_due(
    now: chrono::DateTime<chrono::FixedOffset>,
    at: Option<&str>,
    within: Option<&str>,
) -> Result<chrono::DateTime<chrono::FixedOffset>, String> {
    use chrono::TimeZone;
    let due = match (at.map(str::trim), within.map(str::trim)) {
        (Some(at), None) => chrono::DateTime::parse_from_rfc3339(at)
            .ok()
            .or_else(|| {
                ["%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M:%S"]
                    .iter()
                    .find_map(|f| chrono::NaiveDateTime::parse_from_str(at, f).ok())
                    .and_then(|n| chrono::Local.from_local_datetime(&n).earliest())
                    .map(|t| t.fixed_offset())
            })
            .ok_or_else(|| format!("follow_up: `at` must be local YYYY-MM-DDTHH:MM or ISO with an offset, not {at:?}"))?,
        (None, Some(within)) => {
            let (cut, _) = within.char_indices().last().ok_or("follow_up: `in` is empty")?;
            let (n, unit) = within.split_at(cut);
            let n: i64 = n
                .trim()
                .parse()
                .map_err(|_| format!("follow_up: `in` must be like 30m, 2h or 1d, not {within:?}"))?;
            let secs: i64 = match unit {
                "m" => 60,
                "h" => 3_600,
                "d" => 86_400,
                _ => return Err(format!("follow_up: `in` must end in m, h or d, not {within:?}")),
            };
            n.checked_mul(secs)
                .filter(|s| *s > 0 && *s <= FOLLOW_UP_MAX_DAYS * 86_400)
                .and_then(chrono::TimeDelta::try_seconds)
                .and_then(|d| now.checked_add_signed(d))
                .ok_or_else(|| format!("follow_up: `in` must be more than 0 and at most {FOLLOW_UP_MAX_DAYS} days"))?
        }
        _ => return Err("follow_up: give exactly one of `at` or `in`".into()),
    };
    if due.signed_duration_since(now).num_days() > FOLLOW_UP_MAX_DAYS {
        return Err(format!(
            "follow_up: at most {FOLLOW_UP_MAX_DAYS} days ahead"
        ));
    }
    Ok(due)
}

/// A follow-up's id, as recursive's: `fu_` and FNV-1a 32 of note, due minute and loop.
pub fn follow_up_id(note: &str, due_ms: u64, loop_path: Option<&str>) -> String {
    let text = format!("{note}|{}|{}", due_ms / 60_000, loop_path.unwrap_or(""));
    let mut h: u32 = 0x811c_9dc5;
    for b in text.bytes() {
        h = (h ^ u32::from(b)).wrapping_mul(0x0100_0193);
    }
    format!("fu_{h:08x}")
}

/// A loop's machine-checked close condition (its `Closes when:` line).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CloseWhen {
    /// Subagent `aN` reported its final result.
    AgentDone(String),
    /// Pull request `OWNER/REPO#N` merged.
    PrMerged(String),
    /// The wake run of a follow-up tied to this loop ended with send or ask.
    FollowUpSent,
}

/// The close conditions a loop body names (`Closes when: ...` lines): any
/// case, Markdown emphasis, backticks and end punctuation are ignored.
pub fn close_conditions(body: &str) -> Vec<CloseWhen> {
    let clean = |w: &str| -> String {
        w.trim_matches(|c: char| {
            matches!(
                c,
                '*' | '_' | '`' | '.' | ',' | ';' | ')' | '(' | '"' | '\''
            )
        })
        .to_owned()
    };
    let mut out = Vec::new();
    for line in body.lines() {
        let t: String = line
            .trim()
            .trim_start_matches(['-', '*', ' ', '>'])
            .replace(['*', '`'], "");
        let lower = t.to_lowercase();
        let Some(rest) = lower
            .strip_prefix("closes when:")
            .map(|_| &t["closes when:".len()..])
        else {
            continue;
        };
        for part in rest.split([',', ';']) {
            let w: Vec<String> = part
                .split_whitespace()
                .map(clean)
                .filter(|w| !w.is_empty())
                .collect();
            let lw: Vec<String> = w.iter().map(|x| x.to_lowercase()).collect();
            let l: Vec<&str> = lw.iter().map(String::as_str).collect();
            match l.as_slice() {
                ["agent", id, "done", ..] if valid_agent(id) => {
                    out.push(CloseWhen::AgentDone((*id).to_owned()))
                }
                ["pr", _, "merged", ..] if valid_pr(&w[1]) => {
                    out.push(CloseWhen::PrMerged(w[1].clone()))
                }
                ["follow-up" | "follow_up" | "followup", "sent", ..] => {
                    out.push(CloseWhen::FollowUpSent)
                }
                _ => {}
            }
        }
    }
    out
}

/// `a` and digits: a subagent id.
fn valid_agent(id: &str) -> bool {
    id.strip_prefix('a')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// `OWNER/REPO#N` with plain names and a number: never a `gh` flag.
pub fn valid_pr(pr: &str) -> bool {
    let Some((repo, n)) = pr.split_once('#') else {
        return false;
    };
    let Some((owner, name)) = repo.split_once('/') else {
        return false;
    };
    let plain = |s: &str| {
        !s.is_empty()
            && !s.starts_with(['-', '.'])
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    };
    plain(owner) && plain(name) && !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())
}

/// Whether a subagent's report says its work ended: not a question back,
/// not blocked, not waiting on the person (the host marks interim and
/// stopped runs before this; see `spawns.rs`).
pub fn report_is_final(report: &str) -> bool {
    let t = report.trim();
    let lower = t.to_lowercase();
    let last = lower
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("");
    let open = [
        "blocked",
        "needs you",
        "need you",
        "waiting for you",
        "waiting on you",
        "your call",
        "not landed",
        "unlanded",
        "still running",
        "still working",
        "in progress",
    ];
    !t.is_empty() && !last.trim_end().ends_with('?') && !open.iter().any(|w| lower.contains(w))
}
