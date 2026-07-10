//! Cross-platform diff-session protocol and sidecar runtime.

pub mod benchmark;
pub mod manifest;
pub mod protocol;
pub mod server;

pub const PROTOCOL_VERSION: u32 = 1;
pub const HTTP_PROTOCOL_VERSION: &str =
    "wait-v2 remote-stream manifest-refresh react-app-v2 executable-bound branch-picker-v1";

#[must_use]
pub fn health_response() -> String {
    format!("ok {HTTP_PROTOCOL_VERSION}\n")
}
