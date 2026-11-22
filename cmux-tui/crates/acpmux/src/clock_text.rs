//! Times as RFC 3339 text for the wire, without a date crate.

pub(crate) fn iso(ms: u64) -> String {
    // Minimal RFC3339 without pulling a date crate.
    let secs = (ms / 1000) as i64;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60,
        ms % 1000
    )
}

/// The proleptic Gregorian (year, month, day) of a day count since 1970-01-01 (Howard Hinnant's
/// algorithm).
pub(crate) fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// A strict RFC 3339 time in ms since the epoch: `YYYY-MM-DDTHH:MM:SS`, an
/// optional fraction, then `Z` or `+HH:MM`/`-HH:MM`; a real calendar date at
/// or after 1970. Anything else is `None`.
pub(crate) fn rfc3339_ms(text: &str) -> Option<u64> {
    let b = text.as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let d = b.get(r)?;
        d.iter()
            .all(u8::is_ascii_digit)
            .then(|| d.iter().fold(0, |n, c| n * 10 + i64::from(c - b'0')))
    };
    let sep = |i: usize, c: u8| b.get(i) == Some(&c);
    if !(sep(4, b'-') && sep(7, b'-') && sep(10, b'T') && sep(13, b':') && sep(16, b':')) {
        return None;
    }
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, s) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days_in = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&mo)
        || d < 1
        || days_in.get((mo - 1) as usize).is_none_or(|&last| d > last)
        || h > 23
        || mi > 59
        || s > 59
    {
        return None;
    }
    let mut rest = b.get(19..).unwrap_or_default();
    let mut ms = 0;
    if let Some((b'.', frac)) = rest.split_first() {
        let n = frac.iter().take_while(|c| c.is_ascii_digit()).count();
        if n == 0 {
            return None;
        }
        let scale = match n.min(3) {
            1 => 100,
            2 => 10,
            _ => 1,
        };
        ms = frac.iter().take(n.min(3)).fold(0, |m, c| m * 10 + i64::from(c - b'0')) * scale;
        rest = frac.get(n..).unwrap_or_default();
    }
    let offset = match rest {
        b"Z" => 0,
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
            let digits = [*h1, *h2, *m1, *m2];
            if !digits.iter().all(u8::is_ascii_digit) {
                return None;
            }
            let (oh, om) = (
                i64::from(h1 - b'0') * 10 + i64::from(h2 - b'0'),
                i64::from(m1 - b'0') * 10 + i64::from(m2 - b'0'),
            );
            if oh > 23 || om > 59 {
                return None;
            }
            if *sign == b'-' { -(oh * 60 + om) } else { oh * 60 + om }
        }
        _ => return None,
    };
    // Days since 1970-01-01 (H. Hinnant's days_from_civil).
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    let secs = days * 86_400 + h * 3_600 + mi * 60 + s - offset * 60;
    u64::try_from(secs * 1_000 + ms).ok()
}
