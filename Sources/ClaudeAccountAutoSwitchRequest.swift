import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation

/// A Claude usage-limit report that may move its pane to another account: the pure half of
/// ``ClaudeAccountAutoSwitchCoordinator``.
///
/// Only the `agent.error.reported` event Claude's `StopFailure` hook emits with a `usage_limit`
/// detail qualifies, from a top-level Claude session attributed to a workspace and pane. The
/// hook's second error event, which carries the attention notification, has no detail and never
/// qualifies; neither does a nested session's, whose pane belongs to the outer agent.
struct ClaudeAccountAutoSwitchRequest: Equatable, Sendable {
    /// The failure-class token ``ClaudeStopFailure/journalDetail`` uses for a usage limit.
    static let usageLimitToken = "usage_limit"

    /// The journal event's id, so one report switches at most once.
    let eventId: String
    let workspaceId: UUID
    let panelId: UUID
    /// `usage_limit: <message>`; the message carries the reset time.
    let detail: String
    /// When the hook reported the limit, in milliseconds since 1970.
    let occurredAtMs: Int64
    /// Whether the stopped turn left background work running.
    let pendingWork: Bool

    /// What cmux knows about the pane a report names.
    enum Pane: Equatable, Sendable {
        /// The pane is gone, or cmux knows no Claude session in it.
        case missing
        /// SSH, cloud or remote tmux. Its Claude runs under another machine's accounts, so it is
        /// never switched and nothing is marked exhausted.
        case onAnotherMachine
        /// A switch of this pane is already running: its Claude is about to be replaced.
        case switching
        /// A pane on this Mac whose Claude runs under `current`, resumed in `workingDirectory`.
        /// `registry` holds the user-level accounts only.
        case local(current: ClaudeAccount, registry: ClaudeAccountRegistry, workingDirectory: String?)
    }

    /// Reads a journal event. `nil` unless it is a qualifying usage-limit report and the setting
    /// is on; `isEnabled` is read only for such a report, since every journal event passes here.
    init?(draft: AgentJournalEventDraft, isEnabled: @autoclosure () -> Bool) {
        guard draft.kind == .errorReported, draft.source == "claude", !draft.isSubagent,
              draft.unattributedReason == nil,
              let detail = draft.detail,
              detail == Self.usageLimitToken || detail.hasPrefix(Self.usageLimitToken + ":"),
              let workspaceId = draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let panelId = draft.surfaceId.flatMap(UUID.init(uuidString:)),
              isEnabled() else {
            return nil
        }
        self.eventId = draft.eventId
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.detail = detail
        self.occurredAtMs = draft.occurredAtMs
        self.pendingWork = draft.pendingWork
    }

    /// What to do about this report.
    ///
    /// Ignored, with nothing marked, when the setting went off meanwhile, the pane is not a
    /// local Claude pane, a switch of it is running, or the report predates its last automatic
    /// switch (it came from the replaced Claude). Otherwise the current account is exhausted
    /// until the reset time its limit message gives, or ``ClaudeUsageLimitReset/fallbackInterval``
    /// from `now`. The next account comes from ``ClaudeAccountAutoSwitchPolicy``, trusted ones
    /// first, skipping exhausted accounts and ones without a Claude config. A free account is
    /// still held back when the pane got input after the limit, the turn left background work,
    /// or the pane already went through every other account without finishing a turn.
    ///
    /// - Parameters:
    ///   - pane: What cmux knows about the pane.
    ///   - isEnabled: The setting, read again after the asynchronous trust read.
    ///   - storedExhaustion: The exhaustion file's entries.
    ///   - ledger: What the coordinator remembers in memory.
    ///   - isUsable: Whether an account has a Claude config (its `.claude.json` exists).
    ///   - isTrusted: Whether an account already trusts the session's folder.
    ///   - sourceScreen: The pane's screen now; a typed message in Claude's input box holds the
    ///     switch back, since the restart would discard it.
    func action(
        pane: Pane,
        isEnabled: Bool,
        storedExhaustion: [String: Date],
        ledger: ClaudeAccountAutoSwitchLedger,
        sourceScreen: AgentAutoResumeCoordinator.ScreenState,
        isUsable: (ClaudeAccount) -> Bool,
        isTrusted: (ClaudeAccount) -> Bool,
        now: Date,
        timeZone: TimeZone,
        homeDirectory: String
    ) -> ClaudeAccountAutoSwitchAction {
        guard isEnabled, case .local(let current, let registry, _) = pane else { return .ignore }
        // The replaced Claude's report, delivered late, is not about the account the pane runs now.
        if let lastSwitch = ledger.lastAutomaticSwitchAtMs(panelId: panelId), occurredAtMs < lastSwitch {
            return .ignore
        }
        // A quoted reset that already passed ("Oct 25 at 9am" read that afternoon) would expire at
        // once and leave the account looking free; it counts as unparsed.
        let quotedReset = ClaudeUsageLimitReset.resetDate(inMessage: detail, now: now, timeZone: timeZone)
            .flatMap { $0 > now ? $0 : nil }
        let exhaustion = ClaudeAccountAutoSwitchAction.Exhaustion(
            account: current,
            accountKey: current.exhaustionKey(homeDirectory: homeDirectory),
            until: quotedReset ?? now.addingTimeInterval(ClaudeUsageLimitReset.fallbackInterval),
            quotedReset: quotedReset
        )
        let currentKey = exhaustion.accountKey
        let others = registry.accounts.filter { $0.exhaustionKey(homeDirectory: homeDirectory) != currentKey }
        // An account without a Claude config is passed over like an exhausted one.
        let unusableKeys = others.filter { !isUsable($0) }.map { $0.exhaustionKey(homeDirectory: homeDirectory) }
        switch ClaudeAccountAutoSwitchPolicy.decide(
            failureDetail: detail,
            current: current,
            registry: registry,
            exhaustedKeys: ledger.exhaustedKeys(stored: storedExhaustion, now: now).union(unusableKeys),
            isTrusted: isTrusted,
            homeDirectory: homeDirectory
        ) {
        case .notUsageLimit:
            // Unreachable: a request always carries the usage-limit token.
            return .ignore
        case .noAlternative:
            return .markExhaustedOnly(exhaustion)
        case .switchTo(let target, let sendContinue):
            if pendingWork { return .holdBack(exhaustion, .backgroundWork) }
            if let inUse = ClaudeAccountAutoSwitchAction.HoldBack.paneInUse(
                receivedInputSinceReport: ledger.receivedInput(panelId: panelId, after: occurredAtMs),
                screen: sourceScreen
            ) {
                return .holdBack(exhaustion, inUse)
            }
            // Spec D4: at most one attempt per other account until a turn finishes.
            if ledger.automaticSwitches(panelId: panelId) >= others.count { return .holdBack(exhaustion, .attemptLimit) }
            return .switchAccount(to: target, sendContinue: sendContinue, exhausted: exhaustion)
        }
    }
}
