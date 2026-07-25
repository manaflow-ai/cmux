import Foundation

/// Coalesces explicit transcript fallback lookups and cancels them with the
/// owning agent-session lifecycle.
@MainActor
final class AgentChatFallbackTranscriptResolutionCoordinator {
    typealias Resolver = @Sendable (
        AgentChatSessionRecord,
        ContinuousClock.Instant
    ) async -> String?

    private var pendingResolutions: [
        String: (id: UUID, task: Task<String?, Never>)
    ] = [:]
    private let resolver: Resolver
    private let timeout: Duration

    init(
        transcriptResolver: AgentChatTranscriptResolver,
        resolver: Resolver? = nil,
        timeout: Duration
    ) {
        self.timeout = timeout
        self.resolver = resolver ?? { record, deadline in
            await Self.resolveTranscriptPath(
                resolver: transcriptResolver,
                record: record,
                deadline: deadline
            )
        }
    }

    func resolve(for record: AgentChatSessionRecord) async -> String? {
        if let pending = pendingResolutions[record.sessionID] {
            return await pending.task.value
        }

        let id = UUID()
        let resolver = resolver
        let deadline = ContinuousClock.now + timeout
        let task = Task<String?, Never> {
            let path = await resolver(record, deadline)
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return path
        }
        pendingResolutions[record.sessionID] = (id: id, task: task)

        let path = await task.value
        if pendingResolutions[record.sessionID]?.id == id {
            pendingResolutions.removeValue(forKey: record.sessionID)
        }
        return path
    }

    func cancel(sessionID: String) {
        pendingResolutions.removeValue(forKey: sessionID)?.task.cancel()
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated private static func resolveTranscriptPath(
        resolver: AgentChatTranscriptResolver,
        record: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        resolver.transcriptPath(for: record, deadline: deadline)
    }
}
