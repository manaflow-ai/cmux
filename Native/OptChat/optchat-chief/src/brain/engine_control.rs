//! chief.engine.get / chief.engine.set / chief.stop in the brain: the one
//! op behind the CLI's `chief-control` and the Home Chief Settings panel of
//! a Chief on a paired server (2026-10-08: the panel wrote the laptop's
//! engine.json while the server's brain ran claude-sr). The brain owns its
//! engine.json: a set is checked here (a harness acpmux does not have, an
//! effort no harness takes) and refused with a typed error, never saved
//! for a silent fallback at the next turn.
//!
//! Answer: `{"engine": {harness, model, effort, compactor_harness,
//! compactor_model}, "choice": <engine.json>, "last_turn": <turn.end>|null,
//! "recent": [<turn.end>...]}`, or `{"error": {"code", "message"}}`.

use serde_json::{Value, json};

use super::{Brain, EngineRequest, Phase};
use crate::engine::{EngineChoice, resolve};

/// The efforts acpmux maps onto a harness (`default` clears the field).
pub const EFFORTS: &[&str] = &["minimal", "low", "medium", "high", "xhigh", "max"];

/// How many recent turn ends an answer carries.
const RECENT: usize = 5;

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({"error": {"code": code, "message": message.into()}})
}

/// `default` (or empty) clears a field; an absent one stays.
fn apply(field: &mut Option<String>, value: Option<String>) {
    if let Some(value) = value {
        let value = value.trim();
        *field = (!value.is_empty() && value != "default").then(|| value.to_owned());
    }
}

impl Brain {
    pub(super) fn engine_control(&mut self, request: EngineRequest) -> Value {
        let Some(file) = self.settings.engine_file.clone() else {
            return error(
                "engine_unavailable",
                "this Chief host has no engine.json (its engine is fixed at start)",
            );
        };
        let mut choice = crate::engine::load(&file);
        if let EngineRequest::Set {
            harness,
            model,
            effort,
        } = request
        {
            if let Some(h) = harness.as_deref().map(str::trim)
                && !h.is_empty()
                && h != "default"
                && !self.settings.families.is_empty()
                && !self.settings.families.contains_key(h)
            {
                let known: Vec<&str> = self.settings.families.keys().map(String::as_str).collect();
                return error(
                    "unknown_harness",
                    format!(
                        "acpmux on this host has no harness {h} (it has {})",
                        known.join(", ")
                    ),
                );
            }
            if let Some(e) = effort.as_deref().map(str::trim)
                && !e.is_empty()
                && e != "default"
                && !EFFORTS.contains(&e)
            {
                return error(
                    "invalid_effort",
                    format!("effort {e} is not one of default, {}", EFFORTS.join(", ")),
                );
            }
            apply(&mut choice.harness, harness);
            apply(&mut choice.model, model);
            apply(&mut choice.effort, effort);
            if let Err(e) = crate::engine::save(&file, &choice) {
                return error("write_failed", format!("{}: {e}", file.display()));
            }
            (self.log)(&format!(
                "engine set: {}",
                serde_json::to_string(&choice).unwrap_or_default()
            ));
        }
        self.engine_answer(&choice)
    }

    fn engine_answer(&self, choice: &EngineChoice) -> Value {
        let s = &self.settings;
        let engine = resolve(choice, &s.harness, s.model.as_deref(), s.effort.as_deref());
        let ends: Vec<Value> = s
            .trace_dir
            .as_deref()
            .and_then(|dir| crate::report::read(dir, 0).ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|e| e["ev"] == "turn.end")
            .collect();
        let recent: Vec<Value> = ends.iter().rev().take(RECENT).map(turn_summary).collect();
        json!({
            "engine": {
                "harness": engine.harness,
                "model": engine.model,
                "effort": engine.effort,
                "compactor_harness": choice.compactor_harness,
                "compactor_model": choice.compactor_model,
            },
            "choice": choice,
            "last_turn": recent.first().cloned().unwrap_or(Value::Null),
            "recent": recent,
        })
    }

    /// chief.stop: a running turn stops as for a newer message, and its end
    /// posts what it said and "(turn stopped)".
    pub(super) fn owner_stop(&mut self) -> Value {
        if self.phase != Phase::Running {
            return json!({"stopped": false});
        }
        self.deny_pending("the owner stopped the turn");
        self.owner_stopped = true;
        self.interrupt.request();
        (self.log)("the owner stopped the running turn");
        json!({"stopped": true})
    }
}

/// The fields of a `turn.end` an engine panel shows.
fn turn_summary(end: &Value) -> Value {
    json!({
        "turn": end["turn"],
        "ts": end["ts"],
        "status": end["status"],
        "harness": end["harness"],
        "harness_profile": end["harness_profile"],
        "model": end["model"],
        "effort": end["effort"],
        "ms": end["ms"],
        "tools": end["tools"],
        "tool_errors": end["tool_errors"],
        "cost_usd": end["cost_usd"],
        "usage": end["usage"],
        "reply": end["reply"]["prefix"],
        "error": end["error"]["prefix"],
    })
}
