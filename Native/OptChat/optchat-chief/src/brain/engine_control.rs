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
//! "recent": [<turn.end>...], "offered": {"models": [{id, name, family?,
//! efforts?, fast?, aliases?, ...}...], "efforts": [...], "speeds": [...],
//! "harnesses": [{id, displayName, family, chiefFamily, kind, capabilities,
//! unavailable, unavailableReason?, ...}...]}}` (harness_offer.rs), or
//! `{"error": {"code", "message"}}`.

use serde_json::{Value, json};

use super::{Brain, EngineRequest, Phase, ReactionFields};
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

/// The reaction-wake fields of a set over `choice`; Err: the refusal.
fn apply_reactions(choice: &mut EngineChoice, fields: ReactionFields) -> Result<(), Value> {
    apply(&mut choice.classifier_harness, fields.classifier_harness);
    apply(&mut choice.classifier_model, fields.classifier_model);
    if let Some(prompt) = fields.classifier_prompt {
        // A prompt keeps its own spacing; only `default` or empty clears it.
        choice.classifier_prompt =
            (!prompt.trim().is_empty() && prompt.trim() != "default").then_some(prompt);
    }
    if let Some(on) = fields.reactions_can_wake {
        choice.reactions_can_wake = match on.trim() {
            "" | "default" => None,
            "true" | "on" => Some(true),
            "false" | "off" => Some(false),
            other => {
                return Err(error(
                    "invalid_value",
                    format!("reactions_can_wake is true, false or default, not {other:?}"),
                ));
            }
        };
    }
    Ok(())
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
            speed,
            compactor_speed,
            compactor_harness,
            compactor_model,
            reactions,
        } = request
        {
            // A speed the target harness has (the turns' after this set;
            // the compactor's when acpmux says its family).
            let s = &self.settings;
            // A value this set names (`default` clears instead).
            let set = |value: &Option<String>| {
                value
                    .as_deref()
                    .map(str::trim)
                    .filter(|h| !h.is_empty() && *h != "default")
                    .map(str::to_owned)
            };
            let turn_harness = set(&harness)
                .or_else(|| choice.harness.clone())
                .unwrap_or_else(|| s.harness.clone());
            // The compactor's family after this set: the set harness's, else
            // the turns' when it is Claude, else Claude (a codex Chief
            // compacts on a Claude route; host::compactor_harness_for).
            let compactor_family = match &compactor_harness {
                Some(_) => set(&compactor_harness),
                None => choice.compactor_harness.clone(),
            }
            .map(|h| self.family_of(&h))
            .unwrap_or(crate::acpmux::Family::Claude);
            for (value, family) in [
                (&speed, self.family_of(&turn_harness)),
                (&compactor_speed, compactor_family),
            ] {
                if let Some(v) = value.as_deref()
                    && let Err(reason) = crate::engine::check_speed(v, family)
                {
                    return error("invalid_speed", reason);
                }
            }
            for h in [
                set(&harness),
                set(&compactor_harness),
                set(&reactions.classifier_harness),
            ]
            .into_iter()
            .flatten()
            {
                if !self.settings.families.is_empty() && !self.settings.families.contains_key(&h) {
                    let known: Vec<&str> =
                        self.settings.families.keys().map(String::as_str).collect();
                    return error(
                        "unknown_harness",
                        format!(
                            "acpmux on this host has no harness {h} (it has {})",
                            known.join(", ")
                        ),
                    );
                }
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
            let probe = set(&harness);
            apply(&mut choice.harness, harness);
            apply(&mut choice.model, model);
            apply(&mut choice.effort, effort);
            apply(&mut choice.speed, speed);
            apply(&mut choice.compactor_speed, compactor_speed);
            apply(&mut choice.compactor_harness, compactor_harness);
            apply(&mut choice.compactor_model, compactor_model);
            if let Err(e) = apply_reactions(&mut choice, *reactions) {
                return e;
            }
            if let Err(e) = crate::engine::save(&file, &choice) {
                return error("write_failed", format!("{}: {e}", file.display()));
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
        self.engine_answer(&choice)
    }

    fn engine_answer(&self, choice: &EngineChoice) -> Value {
        // The reaction classifier this Chief runs now (its engine.json over
        // the user's cmux.json, reaction_wake.rs).
        let reactions = self.reaction_config_for(choice);
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
        // The picker's lists: acpmux's models for the turn harness (none
        // when it does not answer; the panel then keeps the current one).
        let models = self
            .agents
            .offered_models(&engine.harness)
            .unwrap_or_else(|e| {
                (self.log)(&format!("engine answer: acpmux models: {e}"));
                Vec::new()
            });
        // The speeds the turns' harness runs (Fast only on codex), as a set checks.
        let family = self.family_of(&engine.harness);
        let speeds: Vec<&str> = crate::engine::SPEEDS
            .iter()
            .copied()
            .filter(|speed| crate::engine::check_speed(speed, family).is_ok())
            .collect();
        // Every engine the picker can switch the next turn to (harness_offer.rs).
        let harnesses = self
            .agents
            .harness_catalog()
            .map(|answer| {
                super::harness_offer::offered_harnesses(&answer, &self.settings.families, |h| {
                    self.family_of(h)
                })
            })
            .unwrap_or_else(|e| {
                (self.log)(&format!("engine answer: acpmux harnesses: {e}"));
                Vec::new()
            });
        json!({
            "engine": {
                "harness": engine.harness,
                "model": engine.model,
                "effort": engine.effort,
                "compactor_harness": choice.compactor_harness,
                "compactor_model": choice.compactor_model,
                "speed": engine.speed.as_deref().unwrap_or("default"),
                "compactor_speed": choice.compactor_speed.as_deref().unwrap_or("default"),
                "classifier_harness": reactions.harness,
                "classifier_model": reactions.model,
                "classifier_prompt": if reactions.prompt == crate::brain::reaction_wake::DEFAULT_PROMPT {
                    ""
                } else {
                    reactions.prompt.as_str()
                },
                "reactions_can_wake": reactions.can_wake,
            },
            "choice": choice,
            "last_turn": recent.first().cloned().unwrap_or(Value::Null),
            "recent": recent,
            "offered": {"models": models, "efforts": EFFORTS, "speeds": speeds, "harnesses": harnesses},
        })
    }

    /// chief.stop: a running turn stops as for a newer message, and its end
    /// posts nothing: the owner already knows they stopped it.
    /// Subagents at work go on: only their own stop (chief.stop {name}) or a
    /// control cancel stops one (2026-10-20: a Home stop while the Chief
    /// worked stopped every subagent).
    pub(super) fn owner_stop(&mut self) -> Value {
        let turn = self.phase == Phase::Running;
        if turn {
            self.owner_stopped = true;
            self.interrupt.request_hard();
            (self.log)("the owner stopped the running turn");
        }
        json!({"stopped": turn})
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
