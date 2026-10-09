//! The next turn's harness, started before the turn (parity item 4): the
//! brain hints acpmux's session pool (`_acpmux/prewarm`) with the exact
//! shape of its next turn session when acpmux connects and after every
//! turn. The next `session/new` of that shape takes the started harness,
//! with its MCP servers up, instead of a cold start. Each turn still gets
//! a fresh conversation: the view is its whole context.

use super::{Brain, Engine};
use crate::acpmux::Family;

impl Brain {
    /// The presets of a turn session on a harness of `family`: the cached
    /// layout's preset (a Claude harness whose acpmux takes a preset system
    /// prompt), and else the preset the session names (the family's own
    /// when the turn left the default harness's family; None: the port's
    /// turn preset).
    pub(super) fn session_presets(&self, family: Family) -> (Option<String>, Option<String>) {
        let cached = (matches!(self.settings.engine, Engine::Acpmux) && family == Family::Claude)
            .then(|| self.settings.turn_preset.clone())
            .flatten()
            .filter(|preset| self.agents.system_prompt(preset));
        let default_family = self.family_of(&self.settings.harness);
        let plain = match family {
            Family::Codex => self.settings.codex_preset.clone(),
            Family::Claude if default_family != family => self.settings.turn_preset.clone(),
            _ => None,
        };
        (cached, plain)
    }

    /// The engine the next turn takes (engine.json over the defaults), and
    /// the harness engine.json named when acpmux does not have it (the
    /// default harness runs instead).
    pub(super) fn next_engine(&self) -> (crate::engine::TurnEngine, Option<String>) {
        let s = &self.settings;
        let choice = s
            .engine_file
            .as_deref()
            .map(crate::engine::load)
            .unwrap_or_default();
        let mut engine =
            crate::engine::resolve(&choice, &s.harness, s.model.as_deref(), s.effort.as_deref());
        let mut unknown = None;
        if !s.families.is_empty() && !s.families.contains_key(&engine.harness) {
            unknown = Some(std::mem::replace(&mut engine.harness, s.harness.clone()));
        }
        (engine, unknown)
    }

    /// Hints the pool with the next turn session's harness profile (as the
    /// harness gate admits it), preset and directory. A failure only costs
    /// the next turn a cold start, so it is logged and nothing else.
    pub(super) fn prewarm_next_turn(&self) {
        if !matches!(self.settings.engine, Engine::Acpmux) || !self.agents_up {
            return;
        }
        let (engine, _) = self.next_engine();
        let (cached, plain) = self.session_presets(self.family_of(&engine.harness));
        let preset = cached.or(plain);
        let hinted =
            crate::harness_gate::admit_live(&*self.agents, &engine.harness).and_then(|admitted| {
                self.agents.prewarm(
                    &admitted.profile,
                    preset.as_deref(),
                    &self.settings.session_dir,
                )
            });
        if let Err(e) = hinted {
            (self.log)(&format!("prewarming the next turn's harness: {e}"));
        }
    }
}
