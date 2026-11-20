//! Shared pure log filters; the implementation lives in acpmux-core.
pub use acpmux_core::chat::record::logged_init::{InitSections, LoggedInit};

#[cfg(test)]
use serde_json::{Value, json};
#[cfg(test)]
#[path = "logged_init_tests.rs"]
mod tests;
