//! Five-field cron (`minute hour day-of-month month day-of-week`) on the
//! person's clock: `*`, `a`, `a-b`, `*/n`, `a-b/n`, comma lists, and month and
//! weekday names (`jan`, `mon-fri`; Sunday is 0 or 7). As in Vixie cron, when
//! both day fields are restricted a day matches either one.

use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime, Timelike};

/// How far ahead `next_after` looks before it calls a schedule impossible
/// (`0 9 30 2 *`): five years holds every leap-day case.
const HORIZON_DAYS: i64 = 5 * 366;

/// A parsed cron expression.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cron {
    minutes: Vec<u32>,
    hours: Vec<u32>,
    days: Vec<u32>,
    months: Vec<u32>,
    weekdays: Vec<u32>,
    days_any: bool,
    weekdays_any: bool,
}

const MONTHS: [&str; 12] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];
const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

impl Cron {
    /// Parses `text`, or says which field is wrong.
    pub fn parse(text: &str) -> Result<Cron, String> {
        let fields: Vec<&str> = text.split_whitespace().collect();
        let [m, h, dom, mon, dow] = fields[..] else {
            return Err(format!(
                "cron {text:?}: 5 fields (minute hour day month weekday)"
            ));
        };
        let mut weekdays = field(dow, 0, 7, &WEEKDAYS, 0)?;
        for d in weekdays.iter_mut() {
            *d %= 7;
        }
        weekdays.sort_unstable();
        weekdays.dedup();
        Ok(Cron {
            minutes: field(m, 0, 59, &[], 0)?,
            hours: field(h, 0, 23, &[], 0)?,
            days: field(dom, 1, 31, &[], 0)?,
            months: field(mon, 1, 12, &MONTHS, 1)?,
            weekdays,
            days_any: dom == "*",
            weekdays_any: dow == "*",
        })
    }

    fn day_matches(&self, d: NaiveDate) -> bool {
        if !self.months.contains(&d.month()) {
            return false;
        }
        let dom = self.days.contains(&d.day());
        let dow = self.weekdays.contains(&d.weekday().num_days_from_sunday());
        match (self.days_any, self.weekdays_any) {
            (false, false) => dom || dow,
            (false, true) => dom,
            (true, false) => dow,
            (true, true) => true,
        }
    }

    /// The first slot strictly after `after_ms` (UTC ms), on a clock
    /// `offset_minutes` east of UTC; None when no slot comes in five years.
    pub fn next_after(&self, after_ms: u64, offset_minutes: i64) -> Option<u64> {
        let offset_ms = offset_minutes * 60_000;
        let local_ms = after_ms as i64 + offset_ms;
        let start = chrono::DateTime::from_timestamp_millis(local_ms)?.naive_utc();
        // The next whole minute after `start`.
        let start = start
            .with_second(0)?
            .with_nanosecond(0)?
            .checked_add_signed(Duration::minutes(1))?;
        let mut day = start.date();
        for _ in 0..HORIZON_DAYS {
            if self.day_matches(day) {
                for &h in &self.hours {
                    for &m in &self.minutes {
                        let t = NaiveDateTime::new(day, chrono::NaiveTime::from_hms_opt(h, m, 0)?);
                        if t >= start {
                            let utc = t.and_utc().timestamp_millis() - offset_ms;
                            return u64::try_from(utc).ok();
                        }
                    }
                }
            }
            day = day.succ_opt()?;
        }
        None
    }
}

/// The values of one field in `lo..=hi`, sorted. `names[k]` stands for
/// `k + first`.
fn field(text: &str, lo: u32, hi: u32, names: &[&str], first: u32) -> Result<Vec<u32>, String> {
    let value = |s: &str| -> Result<u32, String> {
        let s = s.to_ascii_lowercase();
        if let Some(k) = names.iter().position(|n| *n == s) {
            return Ok(k as u32 + first);
        }
        let v: u32 = s
            .parse()
            .map_err(|_| format!("cron field {text:?}: {s:?} is not a number"))?;
        if v < lo || v > hi {
            return Err(format!("cron field {text:?}: {v} is outside {lo}-{hi}"));
        }
        Ok(v)
    };
    let mut out = Vec::new();
    for part in text.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => (
                r,
                s.parse::<u32>()
                    .ok()
                    .filter(|s| *s > 0)
                    .ok_or_else(|| format!("cron field {text:?}: bad step {s:?}"))?,
            ),
            None => (part, 1),
        };
        let (a, b) = if range == "*" {
            (lo, hi)
        } else if let Some((a, b)) = range.split_once('-') {
            (value(a)?, value(b)?)
        } else {
            let a = value(range)?;
            (a, if step > 1 { hi } else { a })
        };
        if a > b {
            return Err(format!("cron field {text:?}: {a} is after {b}"));
        }
        out.extend((a..=b).step_by(step as usize));
    }
    out.sort_unstable();
    out.dedup();
    Ok(out)
}
