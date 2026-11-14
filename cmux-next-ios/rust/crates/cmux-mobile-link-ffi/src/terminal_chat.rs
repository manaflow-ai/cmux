//! Toggle Terminal and Chat on the phone: one tab, two live views of one Claude Code or
//! Codex session (Leo, 2026-11-12: terminal and GUI are two live views of one harness
//! session, instant both ways, mid-turn; on iOS chat is the default with a terminal toggle).
//!
//! The Mac's route decides whether a tab is half of a terminal and chat pair
//! (`cmux-window-rules` `tabs::terminal_chat_toggle`, the one the Mac's
//! `palette.toggleTerminalChat` asks). This module asks that same route and says what it
//! means on the phone, where a pair is one tab with two faces, both kept built:
//! - which faces a tab offers, which one it opens on, and which are enabled
//!   ([`terminal_chat_faces`]);
//! - what a tap on a face does ([`terminal_chat_swap`]);
//! - which of the Mac's acpmux chats already shows a harness session, so the phone
//!   shows that one instead of asking for another ([`terminal_chat_session`]).
//!
//! Swift only binds: it reads the tab's facts, shows what these answer and sends the
//! acpmux adopt the Mac sends (`session/new` with `_meta.acpmux.adopt {harness,
//! agentSessionId, watch: true}`) when the chat face needs a chat.

use cmux_window_rules::tabs::{self, TerminalChatToggle, ToggleFacts};

/// One face of a terminal and chat pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TabFace {
    Terminal,
    Chat,
}

/// The facts of one tab, as the phone reads them.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TerminalChatFacts {
    /// A terminal tab: `agent` and `session` are its agent's report (the hook's agent and
    /// `agent_session_id`).
    pub terminal: bool,
    /// An agent chat tab: `agent` is its harness and `session` the harness session its
    /// acpmux chat resumes or watches (acpmux `agentSessionId`), if any.
    pub chat: bool,
    pub agent: Option<String>,
    pub session: Option<String>,
    /// A chat: a terminal tab the phone lists reports `session`.
    pub running: bool,
    /// A terminal: no chat of the Mac shows `session`, and the Mac's acpmux refused to
    /// make a View Only one for the phone (`remote.adopt_refused`: a remote device adopts
    /// no local session). The chat face waits for a chat the Mac opens.
    pub chat_refused: bool,
}

/// What a tab offers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalChatFaces {
    /// The tab shows the Chat | Terminal control and its page menu's Toggle row.
    pub offered: bool,
    /// The face the tab opens on: chat for a Claude Code or Codex session (Leo's iOS
    /// default), else the tab's own kind.
    pub default_face: TabFace,
    pub chat_enabled: bool,
    pub terminal_enabled: bool,
    /// Why a face is disabled, in the person's words; None when both are enabled.
    pub disabled_reason: Option<String>,
    /// The acpmux harness (`claude` or `codex`) and the harness's session id of the pair.
    pub harness: Option<String>,
    pub session: Option<String>,
}

/// What a tap on face `to` does.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalChatSwap {
    /// Nothing: that face shows already, or the tab offers no toggle.
    Stay,
    /// The tab shows `face`. Both faces stay built, so this is a flag flip with no reload.
    Show { face: TabFace },
    /// A chat's terminal face is the terminal tab running its session: that tab shows, on
    /// its terminal face (the Mac's Toggle reveals that terminal too).
    RevealTerminal { harness: String, session: String },
    /// The face cannot show on the phone; `reason` says why.
    Unavailable { reason: String },
}

/// One of the Mac's acpmux chats (`_acpmux/sessions`), as far as the pairing needs it.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TerminalChatCandidate {
    /// The acpmux session id.
    pub session_id: String,
    /// Its harness (`claude`, `codex`, a profile of one).
    pub harness: String,
    /// The harness's own session id it resumes or watches (`agentSessionId`).
    pub agent_session_id: Option<String>,
    /// A View Only chat (`watching`): it follows the transcript the terminal writes.
    pub watching: bool,
    /// Its status (`closed` chats are skipped).
    pub status: String,
}

/// A chat no terminal runs: the Mac resumes it in a new terminal (its Toggle stops the
/// chat's run first), which the phone does not do yet.
pub const NO_TERMINAL: &str = "No terminal runs this chat. Toggle it on the Mac to resume it in a terminal.";

/// A terminal whose session no chat shows, when the Mac's acpmux makes no View Only chat
/// for a phone: the Mac's Toggle Terminal and Chat opens one, which the phone then shows.
pub const NO_CHAT: &str =
    "This session has no chat yet. Toggle Terminal and Chat on the Mac once to open one here.";

fn route(facts: &TerminalChatFacts) -> TerminalChatToggle {
    tabs::terminal_chat_toggle(&ToggleFacts {
        terminal: facts.terminal,
        chat: facts.chat,
        agent: facts.agent.clone(),
        session: facts.session.clone(),
        running: facts.running,
        ..ToggleFacts::default()
    })
}

/// The faces `facts`' tab offers.
#[uniffi::export]
pub fn terminal_chat_faces(facts: TerminalChatFacts) -> TerminalChatFaces {
    let own = if facts.chat && !facts.terminal { TabFace::Chat } else { TabFace::Terminal };
    let none = TerminalChatFaces {
        offered: false,
        default_face: own,
        chat_enabled: own == TabFace::Chat,
        terminal_enabled: own == TabFace::Terminal,
        disabled_reason: None,
        harness: None,
        session: None,
    };
    let pair = |harness: String, session: String, terminal_enabled: bool| TerminalChatFaces {
        offered: true,
        default_face: TabFace::Chat,
        chat_enabled: true,
        terminal_enabled,
        disabled_reason: (!terminal_enabled).then(|| NO_TERMINAL.to_owned()),
        harness: Some(harness),
        session: Some(session),
    };
    match route(&facts) {
        TerminalChatToggle::NotAgentTab
        | TerminalChatToggle::NoSession
        | TerminalChatToggle::UnsupportedHarness => none,
        // No chat to show: the terminal stays, its chat face shown but disabled with why.
        TerminalChatToggle::ToChat { harness, session } if facts.chat_refused => TerminalChatFaces {
            default_face: TabFace::Terminal,
            chat_enabled: false,
            terminal_enabled: true,
            disabled_reason: Some(NO_CHAT.to_owned()),
            ..pair(harness, session, true)
        },
        TerminalChatToggle::ToChat { harness, session }
        | TerminalChatToggle::ToTerminal { harness, session } => pair(harness, session, true),
        // The Mac's own hand-off: stop the chat's run, resume the session in a new
        // terminal. The phone has no such step, so the terminal face stays disabled.
        TerminalChatToggle::ResumeInTerminal { harness, session } => pair(harness, session, false),
        // The phone sends no hand-off or turn facts, so these never come; were they to,
        // the terminal face waits as above.
        TerminalChatToggle::HandingOff { .. } | TerminalChatToggle::Busy => {
            let harness = tabs::harness(facts.agent.as_deref()).map(str::to_owned);
            let session = facts.session.clone().map(|s| s.trim().to_owned());
            TerminalChatFaces { harness, session, ..pair(String::new(), String::new(), false) }
        }
    }
}

/// What a tap on face `to` does on a tab showing `shown`.
#[uniffi::export]
pub fn terminal_chat_swap(facts: TerminalChatFacts, shown: TabFace, to: TabFace) -> TerminalChatSwap {
    let faces = terminal_chat_faces(facts.clone());
    if !faces.offered || shown == to {
        return TerminalChatSwap::Stay;
    }
    if to == TabFace::Chat && !faces.chat_enabled {
        return TerminalChatSwap::Unavailable {
            reason: faces.disabled_reason.unwrap_or_else(|| NO_CHAT.to_owned()),
        };
    }
    // A terminal tab holds both faces itself: its chat is a View Only chat of its session.
    if facts.terminal || to == TabFace::Chat {
        return TerminalChatSwap::Show { face: to };
    }
    // A chat tab's terminal face is the terminal that runs its session.
    match (faces.terminal_enabled, faces.harness, faces.session) {
        (true, Some(harness), Some(session)) => TerminalChatSwap::RevealTerminal { harness, session },
        _ => TerminalChatSwap::Unavailable {
            reason: faces.disabled_reason.unwrap_or_else(|| NO_TERMINAL.to_owned()),
        },
    }
}

/// The chat among `chats` that already shows `harness` session `session`, if any: a View
/// Only chat first (it follows the terminal), else one that resumed it and is not closed.
/// acpmux would answer an adopt of the session with the same chat
/// (`hub/adoption.rs` `adopted_session`); this spares the phone that round trip.
#[uniffi::export]
pub fn terminal_chat_session(
    chats: Vec<TerminalChatCandidate>,
    harness: String,
    session: String,
) -> Option<String> {
    let family = tabs::harness(Some(&harness))?;
    let session = session.trim();
    if session.is_empty() {
        return None;
    }
    let shows = |chat: &&TerminalChatCandidate| {
        chat.status != "closed"
            && chat.agent_session_id.as_deref().map(str::trim) == Some(session)
            && family_of(&chat.harness) == Some(family)
    };
    let best = chats.iter().filter(shows).max_by_key(|chat| chat.watching)?;
    Some(best.session_id.clone())
}

/// The acpmux harness (`claude` or `codex`) an agent or chat harness names, a profile
/// (`claude-cr`) as its family; None for one acpmux does not adopt.
#[uniffi::export]
pub fn terminal_chat_harness(agent: String) -> Option<String> {
    family_of(&agent).map(str::to_owned)
}

/// The acpmux family of a chat's harness: a profile (`claude-cr`) is its family's.
fn family_of(harness: &str) -> Option<&'static str> {
    tabs::harness(Some(harness)).or_else(|| {
        let head = harness.split(['-', '_', ':']).next()?;
        tabs::harness(Some(head))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(agent: Option<&str>, session: Option<&str>) -> TerminalChatFacts {
        TerminalChatFacts {
            terminal: true,
            agent: agent.map(str::to_owned),
            session: session.map(str::to_owned),
            ..TerminalChatFacts::default()
        }
    }

    fn chat(agent: &str, session: Option<&str>, running: bool) -> TerminalChatFacts {
        TerminalChatFacts {
            chat: true,
            agent: Some(agent.to_owned()),
            session: session.map(str::to_owned),
            running,
            ..TerminalChatFacts::default()
        }
    }

    fn candidate(
        id: &str,
        harness: &str,
        session: &str,
        watching: bool,
        status: &str,
    ) -> TerminalChatCandidate {
        TerminalChatCandidate {
            session_id: id.to_owned(),
            harness: harness.to_owned(),
            agent_session_id: Some(session.to_owned()),
            watching,
            status: status.to_owned(),
        }
    }

    #[test]
    fn a_terminal_running_claude_code_or_codex_opens_on_its_chat() {
        for (agent, harness) in [("claude", "claude"), ("claude-code", "claude"), ("Codex", "codex")] {
            let faces = terminal_chat_faces(terminal(Some(agent), Some("h-1")));
            assert!(faces.offered, "{agent}");
            assert_eq!(faces.default_face, TabFace::Chat, "{agent}");
            assert!(faces.chat_enabled && faces.terminal_enabled, "{agent}");
            assert_eq!(faces.disabled_reason, None);
            assert_eq!(faces.harness.as_deref(), Some(harness));
            assert_eq!(faces.session.as_deref(), Some("h-1"));
        }
    }

    #[test]
    fn a_terminal_with_no_adoptable_session_is_only_a_terminal() {
        for facts in [
            terminal(None, None),
            terminal(Some("claude"), None),
            terminal(Some("claude"), Some("  ")),
            terminal(Some("opencode"), Some("h-1")),
            terminal(None, Some("h-1")),
        ] {
            let faces = terminal_chat_faces(facts.clone());
            assert!(!faces.offered, "{facts:?}");
            assert_eq!(faces.default_face, TabFace::Terminal, "{facts:?}");
            assert!(faces.terminal_enabled && !faces.chat_enabled, "{facts:?}");
            assert_eq!(terminal_chat_swap(facts, TabFace::Terminal, TabFace::Chat), TerminalChatSwap::Stay);
        }
    }

    #[test]
    fn a_chat_a_terminal_runs_offers_both_faces() {
        let faces = terminal_chat_faces(chat("codex", Some("h-2"), true));
        assert!(faces.offered);
        assert_eq!(faces.default_face, TabFace::Chat);
        assert!(faces.chat_enabled && faces.terminal_enabled);
        assert_eq!(faces.harness.as_deref(), Some("codex"));
    }

    #[test]
    fn a_chat_no_terminal_runs_keeps_its_terminal_face_disabled() {
        let faces = terminal_chat_faces(chat("claude", Some("h-3"), false));
        assert!(faces.offered);
        assert!(faces.chat_enabled && !faces.terminal_enabled);
        assert_eq!(faces.disabled_reason.as_deref(), Some(NO_TERMINAL));
        assert_eq!(
            terminal_chat_swap(chat("claude", Some("h-3"), false), TabFace::Chat, TabFace::Terminal),
            TerminalChatSwap::Unavailable { reason: NO_TERMINAL.to_owned() }
        );
    }

    #[test]
    fn a_chat_with_no_outside_session_is_only_a_chat() {
        for facts in
            [chat("claude", None, false), chat("opencode", Some("h"), true), chat("", Some("h"), true)]
        {
            let faces = terminal_chat_faces(facts.clone());
            assert!(!faces.offered, "{facts:?}");
            assert_eq!(faces.default_face, TabFace::Chat);
            assert!(faces.chat_enabled && !faces.terminal_enabled);
        }
        let neither = TerminalChatFacts {
            agent: Some("claude".into()),
            session: Some("h".into()),
            ..Default::default()
        };
        assert!(!terminal_chat_faces(neither).offered);
    }

    #[test]
    fn a_terminal_swaps_its_own_faces_both_ways() {
        let facts = terminal(Some("claude"), Some("h-1"));
        assert_eq!(
            terminal_chat_swap(facts.clone(), TabFace::Chat, TabFace::Terminal),
            TerminalChatSwap::Show { face: TabFace::Terminal }
        );
        assert_eq!(
            terminal_chat_swap(facts.clone(), TabFace::Terminal, TabFace::Chat),
            TerminalChatSwap::Show { face: TabFace::Chat }
        );
        // A tap on the lit face does nothing.
        assert_eq!(terminal_chat_swap(facts, TabFace::Chat, TabFace::Chat), TerminalChatSwap::Stay);
    }

    #[test]
    fn a_terminal_whose_chat_the_mac_refused_stays_a_terminal() {
        let facts = TerminalChatFacts { chat_refused: true, ..terminal(Some("codex"), Some("h-7")) };
        let faces = terminal_chat_faces(facts.clone());
        assert!(faces.offered);
        assert_eq!(faces.default_face, TabFace::Terminal);
        assert!(faces.terminal_enabled && !faces.chat_enabled);
        assert_eq!(faces.disabled_reason.as_deref(), Some(NO_CHAT));
        assert_eq!(
            terminal_chat_swap(facts.clone(), TabFace::Terminal, TabFace::Chat),
            TerminalChatSwap::Unavailable { reason: NO_CHAT.to_owned() }
        );
        assert_eq!(
            terminal_chat_swap(facts, TabFace::Chat, TabFace::Terminal),
            TerminalChatSwap::Show { face: TabFace::Terminal }
        );
    }

    #[test]
    fn a_chat_reveals_the_terminal_running_its_session() {
        assert_eq!(
            terminal_chat_swap(chat("claude", Some(" h-4 "), true), TabFace::Chat, TabFace::Terminal),
            TerminalChatSwap::RevealTerminal { harness: "claude".into(), session: "h-4".into() }
        );
        assert_eq!(
            terminal_chat_swap(chat("claude", Some("h-4"), true), TabFace::Terminal, TabFace::Chat),
            TerminalChatSwap::Show { face: TabFace::Chat }
        );
    }

    #[test]
    fn the_session_s_view_only_chat_is_reused() {
        let chats = vec![
            candidate("a-closed", "claude", "h-1", true, "closed"),
            candidate("a-run", "claude", "h-1", false, "idle"),
            candidate("a-watch", "claude", "h-1", true, "running"),
            candidate("b-codex", "codex", "h-1", true, "idle"),
            candidate("c-other", "claude", "h-9", true, "idle"),
        ];
        assert_eq!(
            terminal_chat_session(chats.clone(), "claude".into(), "h-1".into()).as_deref(),
            Some("a-watch")
        );
        assert_eq!(
            terminal_chat_session(chats.clone(), "codex".into(), "h-1".into()).as_deref(),
            Some("b-codex")
        );
        // A chat that resumed it is the next best; a closed one never.
        let resumed = vec![
            candidate("a-closed", "claude", "h-1", true, "closed"),
            candidate("a-run", "claude", "h-1", false, "idle"),
        ];
        assert_eq!(
            terminal_chat_session(resumed, "claude-code".into(), "h-1".into()).as_deref(),
            Some("a-run")
        );
        // A profile of the harness counts as the harness.
        let profile = vec![candidate("p", "claude-cr", "h-2", true, "idle")];
        assert_eq!(terminal_chat_session(profile, "claude".into(), "h-2".into()).as_deref(), Some("p"));
        // None shows it, an empty session, or an agent acpmux does not adopt: ask acpmux.
        assert_eq!(terminal_chat_session(chats.clone(), "claude".into(), "h-5".into()), None);
        assert_eq!(terminal_chat_session(chats.clone(), "claude".into(), " ".into()), None);
        assert_eq!(terminal_chat_session(chats, "opencode".into(), "h-1".into()), None);
    }

    #[test]
    fn a_harness_profile_names_its_family() {
        assert_eq!(terminal_chat_harness("claude-code".into()).as_deref(), Some("claude"));
        assert_eq!(terminal_chat_harness("claude-cr".into()).as_deref(), Some("claude"));
        assert_eq!(terminal_chat_harness("Codex".into()).as_deref(), Some("codex"));
        assert_eq!(terminal_chat_harness("opencode".into()), None);
    }
}
