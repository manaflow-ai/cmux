import CmuxAgentJournal
import Foundation

/// Retires a `running` pane that the hooks never finished.
///
/// A turn that is interrupted, or cleared mid-flight, emits no Stop hook at
/// all: the pane is told the agent started working and is never told it
/// stopped. No amount of correcting what the hooks *say* fixes an event that
/// never arrives, so this samples what the pane actually shows instead.
///
/// The signal is change, not prose. Agent TUIs redraw their elapsed-time
/// counter while a turn runs — Claude's "Cooked for 41s" ticks every second —
/// so a screen that has not changed across consecutive samples is a screen
/// whose agent is not working. That holds across agents without a per-agent
/// pattern table, which is what a static-text classifier would need and would
/// get wrong: Claude leaves its completed-turn line on screen after the turn
/// ends, so "spinner text present" means nothing.
///
/// Deliberately narrow. It only ever samples panes whose state is already
/// `running`, and only ever moves them to `idle`. It cannot invent a state the
/// hooks never reported, cannot contradict a fresh hook, and cannot repaint a
/// pane that is genuinely working — which also bounds the cost to the few panes
/// making a claim worth checking, rather than every pane on a timer.
enum AgentStateScanner {
    /// What one pane's samples say about whether its agent is still working.
    enum Verdict: Equatable {
        /// The screen is changing, or has not been still long enough yet.
        case working
        /// The screen has been still across the required window: the turn is
        /// over even though no Stop hook ever said so.
        case stale
    }

    /// One pane's accumulated sampling state.
    struct Sample: Equatable {
        /// Hash of the last observed screen. Hashed rather than retained: the
        /// scanner never needs the text again, and keeping terminal contents
        /// alive for every running pane is both memory and exposure.
        var screenHash: Int
        /// When the screen last differed from the sample before it.
        var lastChangedAt: TimeInterval
    }

    /// Folds one observation into a pane's sample and returns the verdict.
    ///
    /// - Parameters:
    ///   - screen: The pane's current visible text.
    ///   - previous: The pane's previous sample, if it has been seen before.
    ///   - now: The current time.
    ///   - stillnessSeconds: How long a screen must be unchanged before the
    ///     turn counts as over.
    /// - Returns: The updated sample and the verdict for this observation.
    static func observe(
        screen: String,
        previous: Sample?,
        now: TimeInterval,
        stillnessSeconds: TimeInterval
    ) -> (sample: Sample, verdict: Verdict) {
        let hash = screen.hashValue
        guard let previous, previous.screenHash == hash else {
            // First sighting, or the screen moved: the clock starts now. A
            // first sighting is never stale, so a pane that starts working
            // between two scans is not retired on the strength of one sample.
            return (Sample(screenHash: hash, lastChangedAt: now), .working)
        }
        let still = now - previous.lastChangedAt
        return (previous, still >= stillnessSeconds ? .stale : .working)
    }

    /// Which of a pane's agent keys this scanner may correct.
    ///
    /// A key qualifies when it claims `running` (a turn that may never have
    /// ended) or reports nothing at all while its agent process is live (a
    /// resumed session that has not spoken yet). Both mean "an agent is here"
    /// and both resolve to `idle` once the screen settles.
    ///
    /// `needsInput` and `error` are deliberately excluded. A pane blocked on a
    /// question is perfectly still — it is waiting for the user — so stillness
    /// says nothing about it, and retiring it would erase the one state the
    /// user most needs to act on. `idle` is excluded because it is already the
    /// answer.
    static func correctableAgentKeys(
        lifecycles: [String: AgentHibernationLifecycleState],
        liveAgentKeys: Set<String>
    ) -> [String] {
        var keys: Set<String> = []
        for (key, state) in lifecycles
        where !AgentHibernationLifecycleStatusKeys.isManualKey(key) && state == .running {
            keys.insert(key)
        }
        for key in liveAgentKeys where !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            switch lifecycles[key] {
            case .none, .some(.unknown), .some(.running):
                keys.insert(key)
            case .some(.idle), .some(.needsInput), .some(.error):
                continue
            }
        }
        return keys.sorted()
    }

    /// Phrases an agent prints when it stops because the account is out of
    /// budget.
    ///
    /// Whole phrases, and only budget ones. The shared error/quota cue would be
    /// disastrous here: agents discuss errors, failures and exceptions
    /// constantly, and this reads their screen. Even so these are only consulted
    /// once a screen has gone still, so an agent *writing* about spend limits
    /// while working is never flagged — its screen is still moving.
    static let limitBannerPhrases = [
        "monthly spend limit",
        "spend limit reached",
        "usage limit reached",
        "hit your usage limit",
        "out of credits",
    ]

    /// Whether a settled screen is showing a budget banner rather than a
    /// finished turn.
    static func screenShowsLimitBanner(_ screen: String) -> Bool {
        let lowered = screen.lowercased()
        return limitBannerPhrases.contains { lowered.contains($0) }
    }

    /// The phase a settled screen resolves to: an agent stopped by its budget
    /// has not finished its work, it cannot continue, so it reads as an error
    /// rather than as ready.
    static func settledPhase(screen: String) -> AgentLifecyclePhase {
        screenShowsLimitBanner(screen) ? .error : .idle
    }

    /// The journal event that retires a stale `running`.
    ///
    /// A `stateChanged` asserting `idle`, which is the one kind the reducer
    /// honours an explicit phase for. It is recorded as an ordinary journal
    /// event rather than written straight to the pane so the scanner stays one
    /// more event producer among the hooks, instead of a second writer that
    /// could disagree with them.
    static func staleRunningEvent(
        agentKey: String,
        sessionId: String?,
        workspaceId: String,
        surfaceId: String,
        occurredAtMs: Int64,
        eventId: String,
        phase: AgentLifecyclePhase = .idle
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            eventId: eventId,
            kind: .stateChanged,
            occurredAtMs: occurredAtMs,
            source: "cmux.scanner",
            agentKey: agentKey,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            declaredPhase: phase,
            detail: phase == .error ? "screen-shows-limit-banner" : "stale-running-screen-still"
        )
    }
}
