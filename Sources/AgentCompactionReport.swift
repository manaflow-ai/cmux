import CMUXAgentLaunch
import Foundation

/// An agent's report that a compaction finished: its PostCompact hook, as
/// the Feed ingested it. Posted on the main actor as
/// ``Notification/Name/agentCompactionFinished``.
struct AgentCompactionReport: Equatable, Sendable {
    /// The hook source slug (`claude`, `codex`).
    let source: String
    let sessionID: String
    let surfaceID: UUID?

    init(source: String, sessionID: String, surfaceID: UUID?) {
        self.source = source
        self.sessionID = sessionID
        self.surfaceID = surfaceID
    }

    init?(event: WorkstreamEvent) {
        guard event.hookEventName == .postCompact else { return nil }
        self.init(
            source: event.source,
            sessionID: event.sessionId,
            surfaceID: event.surfaceId.flatMap(UUID.init(uuidString:))
        )
    }

    init?(notification: Notification) {
        guard let report = notification.userInfo?[Self.userInfoKey] as? AgentCompactionReport else { return nil }
        self = report
    }

    @MainActor
    func post() {
        NotificationCenter.default.post(
            name: .agentCompactionFinished,
            object: nil,
            userInfo: [Self.userInfoKey: self]
        )
    }

    private static let userInfoKey = "report"
}

extension Notification.Name {
    /// An agent finished compacting its context. See ``AgentCompactionReport``.
    static let agentCompactionFinished = Notification.Name("cmux.agentCompactionFinished")
}
