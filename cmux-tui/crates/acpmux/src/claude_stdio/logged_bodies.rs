//! Shared pure log filters; the implementation lives in acpmux-core.
pub use acpmux_core::chat::record::logged_bodies::{
    PROMPT_BODY_KEPT_UNDER, leave_out_bodies, leave_out_prompt_bodies,
};

#[cfg(test)]
use serde_json::{Value, json};
#[cfg(test)]
#[path = "logged_bodies_tests.rs"]
mod tests;
