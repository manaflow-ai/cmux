//! [`super::parse::offer`], or a dev's live module's answer: with the `hot-modules` feature, a
//! debug daemon started with `ACPMUX_HOT_MODULE=<checkout>/…/acpmux_hot_guest.wasm` reads sign-in
//! output with that module and swaps in each rebuild of it, with no restart (crates/acpmux-hot,
//! plans/cmux-next/acpmux-hot-modules-DESIGN.md). Without the feature, or when the module is
//! missing or trapped, this is `parse::offer` itself.

use super::Agent;
use super::parse::{self, Offer};

pub(super) fn offer(agent: Agent, output: &str) -> Option<Offer> {
    #[cfg(feature = "hot-modules")]
    {
        // The module's ABI knows Claude and Codex; the others read natively.
        let hot_agent = match agent {
            Agent::Claude => Some(acpmux_hot::Agent::Claude),
            Agent::Codex => Some(acpmux_hot::Agent::Codex),
            Agent::Gemini | Agent::Grok | Agent::Cursor => None,
        };
        if let Some(hot_agent) = hot_agent
            && let Some(slot) = acpmux_hot::daemon()
            && let Some(answer) = slot.login_offer(hot_agent, output)
        {
            return answer.map(|o| Offer { url: o.url, user_code: o.user_code });
        }
    }
    parse::offer(agent, output)
}
