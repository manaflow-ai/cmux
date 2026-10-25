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

    /// What cmux knows about the pane a report names.
    enum Pane: Equatable, Sendable {
        /// The pane is gone, or cmux knows no Claude session in it.
        case missing
        /// SSH, cloud or remote tmux. Its Claude runs under another machine's accounts, so it is
        /// never switched and nothing is marked exhausted.
        case onAnotherMachine
        /// A pane on this Mac whose Claude runs under `current`, resumed in `workingDirectory`.
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
    }

    /// What to do about this report.
    ///
    /// The current account is exhausted until the reset time its limit message gives, or
    /// ``ClaudeUsageLimitReset/fallbackInterval`` from `now` when it gives none. The next account
    /// comes from ``ClaudeAccountAutoSwitchPolicy``: trusted accounts first, exhausted ones
    /// skipped. A pane on another machine, or one without a Claude session, is ignored before
    /// anything is marked.
    func action(
        pane: Pane,
        exhaustedKeys: Set<String>,
        isTrusted: (ClaudeAccount) -> Bool,
        now: Date,
        timeZone: TimeZone,
        homeDirectory: String
    ) -> ClaudeAccountAutoSwitchAction {
        guard case .local(let current, let registry, _) = pane else { return .ignore }
        let quotedReset = ClaudeUsageLimitReset.resetDate(inMessage: detail, now: now, timeZone: timeZone)
        let exhaustion = ClaudeAccountAutoSwitchAction.Exhaustion(
            account: current,
            accountKey: current.exhaustionKey(homeDirectory: homeDirectory),
            until: quotedReset ?? now.addingTimeInterval(ClaudeUsageLimitReset.fallbackInterval),
            quotedReset: quotedReset
        )
        switch ClaudeAccountAutoSwitchPolicy.decide(
            failureDetail: detail,
            current: current,
            registry: registry,
            exhaustedKeys: exhaustedKeys,
            isTrusted: isTrusted,
            homeDirectory: homeDirectory
        ) {
        case .notUsageLimit:
            // Unreachable: a request always carries the usage-limit token.
            return .ignore
        case .noAlternative:
            return .markExhaustedOnly(exhaustion)
        case .switchTo(let target, let sendContinue):
            return .switchAccount(to: target, sendContinue: sendContinue, exhausted: exhaustion)
        }
    }
}
