import Foundation

actor FileExplorerSSHSessionMonitor {
    typealias Detector = @Sendable (String) -> DetectedSSHSession?

    struct Snapshot: Equatable, Sendable {
        let workspaceId: UUID
        let ttyName: String
        let session: DetectedSSHSession?
    }

    private struct Context: Equatable, Sendable {
        let workspaceId: UUID
        let ttyName: String
    }

    private let pollInterval: Duration
    private let detector: Detector
    private var context: Context?
    private var snapshot: Snapshot?
    private var pollingTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot?>.Continuation] = [:]

    init(
        pollInterval: Duration = .seconds(2),
        detector: @escaping Detector = { TerminalSSHSessionDetector.detectSSH(forTTY: $0) }
    ) {
        self.pollInterval = pollInterval
        self.detector = detector
    }

    func updates() -> AsyncStream<Snapshot?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }
        return stream
    }

    func update(isEnabled: Bool, workspaceId: UUID?, ttyName: String?) {
        let normalizedTTY = ttyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled,
              let workspaceId,
              let normalizedTTY,
              !normalizedTTY.isEmpty else {
            stopPolling(clearSession: true)
            return
        }

        let nextContext = Context(workspaceId: workspaceId, ttyName: normalizedTTY)
        guard context != nextContext || pollingTask == nil else { return }

        stopPolling(clearSession: true)
        context = nextContext
        let detector = detector
        let pollInterval = pollInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let session = await Task.detached(priority: .utility) {
                    detector(nextContext.ttyName)
                }.value
                guard !Task.isCancelled else { return }
                await self?.record(session, for: nextContext)

                do {
                    try await ContinuousClock().sleep(for: pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        stopPolling(clearSession: true)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func record(_ session: DetectedSSHSession?, for expectedContext: Context) {
        guard context == expectedContext else { return }
        let nextSnapshot = Snapshot(
            workspaceId: expectedContext.workspaceId,
            ttyName: expectedContext.ttyName,
            session: session
        )
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot
        yield(nextSnapshot)
    }

    private func stopPolling(clearSession: Bool) {
        pollingTask?.cancel()
        pollingTask = nil
        context = nil
        if clearSession, snapshot != nil {
            snapshot = nil
            yield(nil)
        }
    }

    private func yield(_ snapshot: Snapshot?) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
