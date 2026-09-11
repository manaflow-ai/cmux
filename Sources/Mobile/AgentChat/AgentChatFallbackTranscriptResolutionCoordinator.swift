import Foundation

/// Coalesces explicit transcript fallback lookups and cancels them with the
/// owning agent-session lifecycle.
@MainActor
final class AgentChatFallbackTranscriptResolutionCoordinator {
    typealias Resolver = @Sendable (
        AgentChatSessionRecord,
        ContinuousClock.Instant
    ) async -> String?

    private static let maximumConcurrentResolutions = 4

    private var pendingResolutions: [
        String: (
            id: UUID,
            deadline: ContinuousClock.Instant,
            resolverTask: Task<Void, Never>?,
            deadlineTask: Task<Void, Never>?,
            waiters: [UUID: CheckedContinuation<String?, Never>],
            expired: Bool
        )
    ] = [:]
    private var activeResolutionIDs: Set<UUID> = []
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
        guard !Task.isCancelled else { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                register(
                    waiterID: waiterID,
                    record: record,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, sessionID: record.sessionID)
            }
        }
    }

    func cancel(sessionID: String) {
        guard let pending = pendingResolutions.removeValue(forKey: sessionID) else { return }
        // Cancellation is cooperative. Keep the global slot occupied until the
        // resolver actually returns so non-cooperative scans stay bounded.
        pending.resolverTask?.cancel()
        pending.deadlineTask?.cancel()
        for continuation in pending.waiters.values {
            continuation.resume(returning: nil)
        }
    }

    private func register(
        waiterID: UUID,
        record: AgentChatSessionRecord,
        continuation: CheckedContinuation<String?, Never>
    ) {
        let sessionID = record.sessionID
        if var pending = pendingResolutions[sessionID] {
            guard !pending.expired, ContinuousClock.now < pending.deadline else {
                if !pending.expired {
                    expireResolution(sessionID: sessionID, id: pending.id)
                }
                continuation.resume(returning: nil)
                return
            }
            pending.waiters[waiterID] = continuation
            pendingResolutions[sessionID] = pending
            return
        }

        guard activeResolutionIDs.count < Self.maximumConcurrentResolutions else {
            continuation.resume(returning: nil)
            return
        }

        let id = UUID()
        let deadline = ContinuousClock.now + timeout
        activeResolutionIDs.insert(id)
        pendingResolutions[sessionID] = (
            id: id,
            deadline: deadline,
            resolverTask: nil,
            deadlineTask: nil,
            waiters: [waiterID: continuation],
            expired: false
        )

        let resolver = resolver
        let resolverTask = Task { @MainActor [weak self, resolver] in
            let path = await resolver(record, deadline)
            self?.completeResolution(
                sessionID: sessionID,
                id: id,
                path: path
            )
        }
        let deadlineTask = Task { @MainActor [weak self] in
            // A bounded cancellable deadline keeps fallback I/O from delaying chat history.
            try? await ContinuousClock().sleep(until: deadline)
            guard !Task.isCancelled else { return }
            self?.expireResolution(sessionID: sessionID, id: id)
        }
        guard var pending = pendingResolutions[sessionID], pending.id == id else {
            resolverTask.cancel()
            deadlineTask.cancel()
            return
        }
        pending.resolverTask = resolverTask
        pending.deadlineTask = deadlineTask
        pendingResolutions[sessionID] = pending
    }

    private func completeResolution(
        sessionID: String,
        id: UUID,
        path: String?
    ) {
        guard activeResolutionIDs.remove(id) != nil else { return }
        guard let pending = pendingResolutions[sessionID], pending.id == id else { return }
        pending.deadlineTask?.cancel()
        pendingResolutions.removeValue(forKey: sessionID)
        let resolvedPath = pending.expired || ContinuousClock.now >= pending.deadline
            ? nil
            : path
        for continuation in pending.waiters.values {
            continuation.resume(returning: resolvedPath)
        }
    }

    private func expireResolution(sessionID: String, id: UUID) {
        guard var pending = pendingResolutions[sessionID],
              pending.id == id,
              !pending.expired else { return }
        pending.expired = true
        pending.resolverTask?.cancel()
        let waiters = Array(pending.waiters.values)
        pending.waiters.removeAll()
        pendingResolutions[sessionID] = pending
        for continuation in waiters {
            continuation.resume(returning: nil)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, sessionID: String) {
        guard var pending = pendingResolutions[sessionID],
              let continuation = pending.waiters.removeValue(forKey: waiterID) else { return }
        pendingResolutions[sessionID] = pending
        continuation.resume(returning: nil)
    }

    /// Runs the synchronous filesystem resolver on a utility executor because
    /// this coordinator owns the caller-facing state on ``MainActor``.
    nonisolated private static func resolveTranscriptPath(
        resolver: AgentChatTranscriptResolver,
        record: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        let scanTask = Task.detached(priority: .utility) {
            resolver.transcriptPath(for: record, deadline: deadline)
        }
        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }
}
