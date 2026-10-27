//! The host side of a cmux screen stream: holds a room on the signal
//! Worker, answers a viewer's WebRTC offer with the screen as a video track
//! (hardware H.264 where the platform has it), and hands the viewer's input
//! to the platform backend.
//!
//! Platform code is only capture and input (`backend`); signaling, sessions,
//! quality and reconnect rules are shared by every platform.

pub mod backend;
pub mod host;
pub mod signal;

pub use host::Host;

/// A timestamped log line on stderr (`[8:01:21 PM]`-style, local clock not needed).
pub fn log(message: impl AsRef<str>) {
    let elapsed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let seconds = elapsed.as_secs() % 86_400;
    eprintln!("[{:02}:{:02}:{:02} UTC] {}", seconds / 3600, seconds / 60 % 60, seconds % 60, message.as_ref());
}

/// Microseconds on a monotonic clock shared by every frame of this process.
pub fn clock_us() -> i64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_micros() as i64
}
