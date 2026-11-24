//! TEMP blocked-stall tracing (BLK_TRACE=1). Not for commit.
use std::net::SocketAddr;
use std::sync::OnceLock;
use std::time::Instant;

static T0: OnceLock<Instant> = OnceLock::new();
static ON: OnceLock<bool> = OnceLock::new();

pub(crate) fn on() -> bool {
    *ON.get_or_init(|| std::env::var("BLK_TRACE").is_ok_and(|v| v == "1"))
}

pub(crate) fn ms() -> f64 {
    T0.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

pub(crate) fn desc(d: &[u8]) -> String {
    let u32le = |i: usize| d.get(i..i + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).unwrap_or(0);
    match d.first() {
        Some(1) if d.len() == 148 => format!("INIT s={:08x}", u32le(4)),
        Some(2) if d.len() == 92 => format!("RESP s={:08x} r={:08x}", u32le(4), u32le(8)),
        Some(3) if d.len() == 64 => format!("COOKIE r={:08x}", u32le(4)),
        Some(4) if d.len() >= 32 => {
            let c = d.get(8..16).map(|b| u64::from_le_bytes(b.try_into().unwrap())).unwrap_or(0);
            format!("DATA r={:08x} n={c} len={}", u32le(4), d.len())
        }
        _ => format!("OTHER len={} b0={:?}", d.len(), d.first()),
    }
}

pub(crate) fn log(side: impl std::fmt::Display, what: &str, addr: Option<SocketAddr>, d: &[u8]) {
    if on() {
        eprintln!("BLK {:.1} {side} {what} {} {}", ms(), addr.map(|a| a.to_string()).unwrap_or_default(), desc(d));
    }
}

pub(crate) fn note(side: impl std::fmt::Display, what: impl std::fmt::Display) {
    if on() {
        eprintln!("BLK {:.1} {side} {what}", ms());
    }
}
