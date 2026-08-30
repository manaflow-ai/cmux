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

    private let detector: Detector
    private var context: Context?
    private var snapshot: Snapshot?
    private var detectionTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot?>.Continuation] = [:]

    init(
        detector: @escaping Detector = { ttyName in
            TerminalSSHSessionDetector().detectSSH(forTTY: ttyName)
        }
    ) {
        self.detector = detector
    }

    deinit {
        detectionTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
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
            stopDetection(clearSession: true)
            return
        }

        let nextContext = Context(workspaceId: workspaceId, ttyName: normalizedTTY)
        context = nextContext
        detectionTask?.cancel()
        let detector = detector
        detectionTask = Task { [weak self] in
            guard self != nil else { return }
            let session = await Task.detached(priority: .utility) {
                detector(nextContext.ttyName)
            }.value
            guard !Task.isCancelled, let self else { return }
            await self.record(session, for: nextContext)
        }
    }

    func stop() {
        stopDetection(clearSession: true)
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

    private func stopDetection(clearSession: Bool) {
        detectionTask?.cancel()
        detectionTask = nil
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
