//! Whether a user's reaction on a Chief message wakes the Chief (a416,
//! Lawrence 2026-10-21 msg 9070). Stub: the classifier is not wired yet.

use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use crate::engine::EngineChoice;

/// The classifier's model when nothing sets one: Claude Haiku.
pub const DEFAULT_MODEL: &str = "claude-haiku-5-5";

/// One classifier question: the harness (None: the host's Claude route),
/// the model, and the whole prompt text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JudgeAsk {
    pub harness: Option<String>,
    pub model: String,
    pub prompt: String,
}

/// The cheap model that answers `WAKE: reason` or `SKIP: reason`.
pub trait ReactionJudge: Send + Sync {
    fn judge(&self, ask: &JudgeAsk) -> Result<String, String>;
}

/// The settings in force for one decision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReactionWakeConfig {
    pub can_wake: bool,
    pub harness: Option<String>,
    pub model: String,
    pub prompt: String,
}

impl ReactionWakeConfig {
    pub fn resolve(_choice: &EngineChoice, _user: Option<&Value>) -> ReactionWakeConfig {
        ReactionWakeConfig {
            can_wake: false,
            harness: None,
            model: String::new(),
            prompt: String::new(),
        }
    }
}

/// The brain's reaction-wake state.
#[derive(Default)]
pub(super) struct State {
    pub judge: Option<Arc<dyn ReactionJudge>>,
    pub debounce: Option<Duration>,
    pub wake_override: Option<bool>,
    pub user_settings: Option<Option<Value>>,
}

impl super::Brain {
    /// The classifier (the host's acpmux one-shot session; tests a fake).
    pub fn set_reaction_judge(&mut self, judge: Arc<dyn ReactionJudge>) {
        self.reaction_wake.judge = Some(judge);
    }

    /// How long reactions settle before one decision (default 1.5 s).
    pub fn set_reaction_debounce(&mut self, wait: Duration) {
        self.reaction_wake.debounce = Some(wait);
    }

    /// This Chief's `reactions_can_wake` over its engine.json (tests).
    pub fn set_reaction_wake_override(&mut self, on: Option<bool>) {
        self.reaction_wake.wake_override = on;
    }

    /// The user's settings document in place of cmux.json (tests).
    pub fn set_reaction_user_settings(&mut self, doc: Option<Value>) {
        self.reaction_wake.user_settings = Some(doc);
    }
}
