import Foundation
import Observation

/// The wrap-up recap cards the person dismissed on this phone (NextStepCard's ×, #51353), by Mac,
/// chat and turn: a dismissed card leaves no row in the transcript and stays gone when the chat
/// opens again. Kept in this phone's defaults, the newest `limit` (oldest first out), as the Mac
/// keeps its dismissed recaps on its device (`recapDismissed.ts`, `wrapUpDismissed.ts`).
@MainActor
@Observable
public final class WrapUpDismissals {
    public static let shared = WrapUpDismissals()
    static let defaultsKey = "cmux.chat.wrapUpDismissed.v1"
    static let limit = 500

    /// Every dismissed card's key (`key(_:turnID:)`), oldest first.
    private(set) var keys: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
#if DEBUG
        // A UI test's first launch starts with none dismissed (WrapUpDismissUITests).
        if defaults === UserDefaults.standard, ProcessInfo.processInfo.arguments.contains("-cmux-mobile-reset-wrap-up-dismissals") {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
#endif
        keys = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    static func chat(_ summary: AgentSessionSummary) -> String { "\(summary.macID)|\(summary.id)|" }
    static func key(_ summary: AgentSessionSummary, turnID: String) -> String { chat(summary) + turnID }

    /// The turns of this chat whose wrap-up recap was dismissed.
    func dismissedTurns(in summary: AgentSessionSummary) -> Set<String> {
        let prefix = Self.chat(summary)
        return Set(keys.lazy.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    public func dismiss(_ summary: AgentSessionSummary, turnID: String) {
        let key = Self.key(summary, turnID: turnID)
        guard !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
        defaults.set(keys, forKey: Self.defaultsKey)
    }
}
