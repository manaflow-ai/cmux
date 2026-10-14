//! chief.engine.get / chief.engine.set / chief.stop in the brain: the one
//! op behind the CLI's `chief-control` and the Home Chief Settings panel of
//! a Chief on a paired server (2026-10-08: the panel wrote the laptop's
//! engine.json while the server's brain ran claude-sr). The brain owns its
//! engine.json: a set is checked here (a harness acpmux does not have, an
//! effort no harness takes) and refused with a typed error, never saved
//! for a silent fallback at the next turn.
//!
//! Answer: `{"engine": {harness, model, model_is_default, effort,
//! compactor_harness, compactor_model}, "choice": <engine.json>, "avatar":
//! <text>|null, "last_turn": <turn.end>|null, "recent": [<turn.end>...],
//! "offered": {"models": [{id, name}...], "default_model": {id, name}|null,
//! "efforts": [...]}}`, or `{"error": {"code", "message"}}`.
//!
//! `engine.model` is the model turns run: the chosen one, else what the
//! default resolves to (the last turn on this harness, else the curated
//! catalog's default), with `model_is_default` true; null when unknown. The
//! offered `default` entry names it too ("Default (GPT-6.1 Sol)").
//!
//! `avatar` is profile.json's text (`crate::profile`), null for none or a
//! picture (only the Mac shows pictures). A set with `avatar` writes it; ""
//! clears it.

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
        let profile = crate::profile::path_beside(&file);
        if let EngineRequest::Set {
            harness,
            model,
            effort,
            speed,
            compactor_speed,
            avatar,
        } = request
        {
            let avatar = match avatar.as_deref().map(crate::profile::check_avatar) {
                Some(Err(reason)) => return error("invalid_avatar", reason),
                Some(Ok(text)) => Some(text),
                None => None,
            };
            // A speed the target harness has (the turns' after this set;
            // the compactor's when acpmux says its family).
            let s = &self.settings;
            let turn_harness = harness
                .as_deref()
                .map(str::trim)
                .filter(|h| !h.is_empty() && *h != "default")
                .map(str::to_owned)
                .or_else(|| choice.harness.clone())
                .unwrap_or_else(|| s.harness.clone());
            let compactor_harness = choice
                .compactor_harness
                .clone()
                .unwrap_or_else(|| turn_harness.clone());
            for (value, target) in [
                (&speed, &turn_harness),
                (&compactor_speed, &compactor_harness),
            ] {
                if let Some(v) = value.as_deref()
                    && let Err(reason) = crate::engine::check_speed(v, self.family_of(target))
                {
                    return error("invalid_speed", reason);
                }
            }
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
            // acpmux probed only the harnesses the Chief used at its start
            // (ACPMUX_PROBE_HARNESSES): a new turn harness is probed now.
            let probe = harness
                .as_deref()
                .map(str::trim)
                .filter(|h| !h.is_empty() && *h != "default")
                .map(str::to_owned);
            apply(&mut choice.harness, harness);
            apply(&mut choice.model, model);
            apply(&mut choice.effort, effort);
            apply(&mut choice.speed, speed);
            apply(&mut choice.compactor_speed, compactor_speed);
            if let Err(e) = crate::engine::save(&file, &choice) {
                return error("write_failed", format!("{}: {e}", file.display()));
            }
            if let Some(text) = avatar.as_deref() {
                if let Err(e) = crate::profile::save_avatar(&profile, text) {
                    return error("write_failed", format!("{}: {e}", profile.display()));
                }
                (self.log)(&format!(
                    "avatar set: {}",
                    if text.is_empty() { "cleared" } else { "text" }
                ));
            }
            (self.log)(&format!(
                "engine set: {}",
                serde_json::to_string(&choice).unwrap_or_default()
            ));
            if let Some(h) = probe.as_deref()
                && let Err(e) = self.agents.probe_models(h)
            {
                (self.log)(&format!("engine set: asking acpmux to probe {h}: {e}"));
            }
        }
        let mut answer = self.engine_answer(&choice);
        answer["avatar"] = json!(crate::profile::avatar_text(&profile));
        answer
    }

    fn engine_answer(&self, choice: &EngineChoice) -> Value {
        let s = &self.settings;
        let engine = resolve(choice, &s.harness, s.model.as_deref(), s.effort.as_deref());
        let events: Vec<Value> = s
            .trace_dir
            .as_deref()
            .and_then(|dir| crate::report::read(dir, 0).ok())
            .unwrap_or_default();
        let ends: Vec<Value> = events
            .iter()
            .filter(|e| e["ev"] == "turn.end")
            .cloned()
            .collect();
        let recent: Vec<Value> = ends.iter().rev().take(RECENT).map(turn_summary).collect();
        // The picker's lists: acpmux's models for the turn harness (none
        // when it does not answer; the panel then keeps the current one).
        let mut models = self
            .agents
            .offered_models(&engine.harness)
            .unwrap_or_else(|e| {
                (self.log)(&format!("engine answer: acpmux models: {e}"));
                Vec::new()
            });
        let default_model = engine
            .model
            .is_none()
            .then(|| resolve_default(&engine.harness, &events, &mut models))
            .flatten();
        let model = engine.model.clone().or_else(|| {
            default_model
                .as_ref()
                .and_then(|m| m["id"].as_str())
                .map(str::to_owned)
        });
        json!({
            "engine": {
                "harness": engine.harness,
                "model": model,
                "model_is_default": engine.model.is_none(),
                "effort": engine.effort,
                "compactor_harness": choice.compactor_harness,
                "compactor_model": choice.compactor_model,
                "speed": engine.speed.as_deref().unwrap_or("default"),
                "compactor_speed": choice.compactor_speed.as_deref().unwrap_or("default"),
            },
            "choice": choice,
            "last_turn": recent.first().cloned().unwrap_or(Value::Null),
            "recent": recent,
            "offered": {"models": models, "default_model": default_model, "efforts": EFFORTS},
        })
    }

    /// chief.stop: a running turn stops as for a newer message, and its end
    /// posts what it said and "(turn stopped)".
    /// Every subagent at work stops too (the reference client's stop).
    pub(super) fn owner_stop(&mut self) -> Value {
        let subagents = self.stop_subagents();
        let turn = self.phase == Phase::Running;
        if turn {
            self.deny_pending("the owner stopped the turn");
            self.owner_stopped = true;
            self.interrupt.request();
            (self.log)("the owner stopped the running turn");
        }
        if subagents.is_empty() {
            return json!({"stopped": turn});
        }
        (self.log)(&format!(
            "the owner stopped subagents {}",
            subagents.join(", ")
        ));
        json!({"stopped": true, "subagents": subagents})
    }
}

/// The fields of a `turn.end` an engine panel shows.
/// What the default model runs on `harness`: the model the provider reported
/// for the newest default-model turn on it (its `request` events: what the
/// harness really picked), else the curated catalog's default
/// (`catalog_default`). Names the offered `default` entry after it
/// ("Default (GPT-6.1 Sol)", `resolves_to` its id). None: unknown.
fn resolve_default(harness: &str, events: &[Value], models: &mut [Value]) -> Option<Value> {
    let on_default = |e: &&Value| {
        e["ev"] == "turn.end"
            && e["model"].is_null()
            && (e["harness"] == harness || e["harness_profile"] == harness)
    };
    let ran = events.iter().rev().filter(on_default).find_map(|end| {
        events
            .iter()
            .rev()
            .filter(|e| e["ev"] == "request" && e["turn"] == end["turn"])
            .find_map(|e| e["model"].as_str().map(str::trim).filter(|m| !m.is_empty()))
            .map(str::to_owned)
    });
    let id = ran.or_else(|| {
        models
            .iter()
            .find(|m| m["catalog_default"] == true)
            .and_then(|m| m["id"].as_str())
            .map(str::to_owned)
    })?;
    let name = models
        .iter()
        .find(|m| m["id"] == id.as_str())
        .and_then(|m| m["name"].as_str())
        .unwrap_or(&id)
        .to_owned();
    for entry in models.iter_mut().filter(|m| m["id"] == "default") {
        entry["name"] = json!(format!("Default ({name})"));
        entry["resolves_to"] = json!(id);
    }
    Some(json!({"id": id, "name": name}))
}

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
