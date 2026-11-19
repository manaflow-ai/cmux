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

/// The check-in modes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
        "[check-in] Your scheduled check-in ({slot}). Open loops:\n{}\nFor each loop: memory_read it if you need its details, then act on what is due or stale (tell its agent, start the work, set a wake for later), and forget the loops that are done. Send your person one short line only when they must know something new or decide something now; never repeat what you already told them. When nothing needs saying, call stop(): nothing is posted.",
        list.join("\n")
    )
}
