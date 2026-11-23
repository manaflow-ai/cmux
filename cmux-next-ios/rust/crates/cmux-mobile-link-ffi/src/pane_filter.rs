//! Which of a workspace's panes the phone's tab overview shows: agent
//! sessions only, or agent sessions and terminals, with browsers (and the
//! Mac's simulator screens) behind their own toggle.
//!
//! Leo, 2026-11-23: "we want a ... filtering mechanism for only agent
//! sessions, agent sessions/terminals, and ... browsers on their own honestly
//! should be a ... toggle. ... The rare ... case you're looking at a dev
//! server case, ok. But we tuck that ... in some kinda toggle or setting
//! filter whatever."
//!
//! The rule is a pure function of the panes' kinds, the open pane and the
//! filter, so Swift asks it on every list change and only renders. It is
//! linear in the number of panes: the overview's cost stays constant per
//! pane however many the Mac has.
//!
//! [`PaneFilter::default`] is agent sessions and terminals, browsers tucked
//! behind their toggle: Leo called the dev-server browser case rare and said
//! to tuck it in a toggle (his proxy's answer on the default, 2026-11-23).

/// What a pane is, as the overview sorts it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PaneKind {
    /// An agent session (a chat).
    Agent,
    /// A terminal.
    Terminal,
    /// A web page.
    Browser,
    /// A streamed simulator screen: the same dev-server case as a browser.
    Simulator,
    /// A kind this build does not know (a newer Mac's): always shown, since a
    /// filter must never hide what it cannot name.
    Other,
}

/// The overview's main choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PaneScope {
    /// Agent sessions only.
    Agents,
    /// Agent sessions and terminals.
    AgentsAndTerminals,
}

/// The overview's filter: a scope, and whether browsers and simulator
/// screens show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PaneFilter {
    pub scope: PaneScope,
    pub show_browsers: bool,
}

impl Default for PaneFilter {
    /// Agent sessions and terminals; browsers and simulator screens one toggle
    /// away.
    fn default() -> Self {
        Self { scope: PaneScope::AgentsAndTerminals, show_browsers: false }
    }
}

/// What the overview shows under a filter.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct PaneFilterResult {
    /// Indices into the panes, in their order, of the panes shown.
    pub shown: Vec<u32>,
    /// Panes hidden, by what hid them, for the control's count and the
    /// header's "3 of 7": a hidden browser never looks lost.
    pub hidden_terminals: u32,
    pub hidden_browsers: u32,
    /// The filter hides something: the control shows as on.
    pub filtering: bool,
}

/// The overview's filter until the person picks another: agent sessions and
/// terminals, browsers behind their toggle.
#[uniffi::export]
pub fn pane_filter_default() -> PaneFilter {
    PaneFilter::default()
}

/// Whether one pane of `kind` shows under `filter`, before the open-pane rule.
#[uniffi::export]
pub fn pane_filter_shows(filter: PaneFilter, kind: PaneKind) -> bool {
    match kind {
        PaneKind::Agent | PaneKind::Other => true,
        PaneKind::Terminal => filter.scope == PaneScope::AgentsAndTerminals,
        PaneKind::Browser | PaneKind::Simulator => filter.show_browsers,
    }
}

/// The panes the overview shows. `active` is the open pane's index: it always
/// shows, so opening the overview from a pane the filter hides still zooms
/// out of its own card, and the way back to it is one tap.
#[uniffi::export]
pub fn pane_filter_apply(kinds: Vec<PaneKind>, active: Option<u32>, filter: PaneFilter) -> PaneFilterResult {
    let mut result = PaneFilterResult { shown: Vec::with_capacity(kinds.len()), ..Default::default() };
    for (index, kind) in kinds.iter().enumerate() {
        // An index past u32 is past any list the Mac can send; stop there.
        let Ok(index) = u32::try_from(index) else { break };
        if pane_filter_shows(filter, *kind) || active == Some(index) {
            result.shown.push(index);
            continue;
        }
        match kind {
            PaneKind::Terminal => result.hidden_terminals += 1,
            PaneKind::Browser | PaneKind::Simulator => result.hidden_browsers += 1,
            PaneKind::Agent | PaneKind::Other => {}
        }
    }
    result.filtering = result.hidden_terminals + result.hidden_browsers > 0;
    result
}

/// The filter as one stable word, for the phone's settings: it never changes
/// for a filter, so a saved choice survives updates.
#[uniffi::export]
pub fn pane_filter_encode(filter: PaneFilter) -> String {
    let scope = match filter.scope {
        PaneScope::Agents => "agents",
        PaneScope::AgentsAndTerminals => "agents+terminals",
    };
    if filter.show_browsers { format!("{scope}+browsers") } else { scope.to_owned() }
}

/// A saved filter back; anything unreadable (an empty or newer setting) is
/// the default, so a bad value can never hide panes.
#[uniffi::export]
pub fn pane_filter_decode(saved: String) -> PaneFilter {
    let (scope, show_browsers) = match saved.strip_suffix("+browsers") {
        Some(scope) => (scope, true),
        None => (saved.as_str(), false),
    };
    match scope {
        "agents" => PaneFilter { scope: PaneScope::Agents, show_browsers },
        "agents+terminals" => PaneFilter { scope: PaneScope::AgentsAndTerminals, show_browsers },
        _ => PaneFilter::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::PaneKind::{Agent, Browser, Other, Simulator, Terminal};
    use super::*;

    const AGENTS: PaneFilter = PaneFilter { scope: PaneScope::Agents, show_browsers: false };
    const AGENTS_TERMINALS: PaneFilter =
        PaneFilter { scope: PaneScope::AgentsAndTerminals, show_browsers: false };
    const AGENTS_BROWSERS: PaneFilter = PaneFilter { scope: PaneScope::Agents, show_browsers: true };
    const EVERYTHING: PaneFilter = PaneFilter { scope: PaneScope::AgentsAndTerminals, show_browsers: true };

    fn mixed() -> Vec<PaneKind> {
        vec![Agent, Terminal, Browser, Agent, Simulator, Terminal, Other]
    }

    #[test]
    fn the_default_tucks_browsers_behind_their_toggle() {
        assert_eq!(pane_filter_default(), AGENTS_TERMINALS);
        let result = pane_filter_apply(mixed(), None, pane_filter_default());
        assert_eq!(result.shown, vec![0, 1, 3, 5, 6]);
        assert_eq!(result.hidden_browsers, 2);
        assert!(result.filtering);
    }

    #[test]
    fn showing_browsers_shows_every_pane() {
        let result = pane_filter_apply(mixed(), None, EVERYTHING);
        assert_eq!(result.shown, vec![0, 1, 2, 3, 4, 5, 6]);
        assert!(!result.filtering);
    }

    #[test]
    fn agents_only_hides_terminals_and_browsers() {
        let result = pane_filter_apply(mixed(), None, AGENTS);
        assert_eq!(result.shown, vec![0, 3, 6]);
        assert_eq!((result.hidden_terminals, result.hidden_browsers), (2, 2));
        assert!(result.filtering);
    }

    #[test]
    fn agents_and_terminals_hides_browsers_and_simulators() {
        let result = pane_filter_apply(mixed(), None, AGENTS_TERMINALS);
        assert_eq!(result.shown, vec![0, 1, 3, 5, 6]);
        assert_eq!((result.hidden_terminals, result.hidden_browsers), (0, 2));
    }

    #[test]
    fn the_browser_toggle_stands_on_its_own() {
        let result = pane_filter_apply(mixed(), None, AGENTS_BROWSERS);
        assert_eq!(result.shown, vec![0, 2, 3, 4, 6]);
        assert_eq!((result.hidden_terminals, result.hidden_browsers), (2, 0));
    }

    #[test]
    fn the_open_pane_always_shows() {
        let result = pane_filter_apply(mixed(), Some(2), AGENTS);
        assert_eq!(result.shown, vec![0, 2, 3, 6]);
        assert_eq!(result.hidden_browsers, 1);
        let out_of_range = pane_filter_apply(mixed(), Some(99), AGENTS);
        assert_eq!(out_of_range.shown, vec![0, 3, 6]);
    }

    #[test]
    fn an_unknown_kind_is_never_hidden() {
        for filter in [AGENTS, AGENTS_TERMINALS, AGENTS_BROWSERS, EVERYTHING] {
            assert!(pane_filter_shows(filter, Other));
            assert!(pane_filter_shows(filter, Agent));
        }
    }

    #[test]
    fn a_filter_that_matches_nothing_hides_everything_it_names() {
        let result = pane_filter_apply(vec![Terminal, Browser], None, AGENTS);
        assert!(result.shown.is_empty());
        assert!(result.filtering);
        assert!(pane_filter_apply(vec![], None, AGENTS).shown.is_empty());
    }

    #[test]
    fn every_filter_round_trips_through_its_saved_word() {
        for filter in [AGENTS, AGENTS_TERMINALS, AGENTS_BROWSERS, EVERYTHING] {
            assert_eq!(pane_filter_decode(pane_filter_encode(filter)), filter);
        }
        assert_eq!(pane_filter_encode(EVERYTHING), "agents+terminals+browsers");
    }

    #[test]
    fn an_unreadable_saved_filter_is_the_default() {
        for saved in ["", "terminals", "agents+", "+browsers", "everything+browsers"] {
            assert_eq!(pane_filter_decode(saved.to_owned()), PaneFilter::default(), "{saved}");
        }
    }

    /// The overview's cost per pane is constant: a thousand panes take one
    /// pass and keep their order.
    #[test]
    fn many_panes_keep_their_order() {
        let kinds: Vec<PaneKind> = (0..1000).map(|i| if i % 3 == 0 { Agent } else { Terminal }).collect();
        let result = pane_filter_apply(kinds, Some(1), AGENTS);
        assert_eq!(result.shown.len(), 335);
        assert!(result.shown.windows(2).all(|pair| pair[0] < pair[1]));
        // 666 terminals, less the open one.
        assert_eq!(result.hidden_terminals, 665);
    }
}
