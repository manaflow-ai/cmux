import Foundation

/// Detects the foreground plain-SSH session for the terminal selected by Files.
///
/// Detection is scoped to one workspace, panel, and controlling TTY. A result
/// from an older selection is discarded before it can be published, so an
/// inactive terminal cannot replace the selected terminal's file root.
actor FileExplorerSSHSessionMonitor {
    typealias Detector = @Sendable (String) -> DetectedSSHSession?

    struct Snapshot: Equatable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let ttyName: String
        let session: DetectedSSHSession?
    }

    private struct Context: Equatable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let ttyName: String
    }

    private let detector: Detector
    private var context: Context?
    private var snapshot: Snapshot?
    private var detectionTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot?>.Continuation] = [:]

    init(detector: @escaping Detector = { ttyName in
        TerminalSSHSessionDetector.detect(forTTY: ttyName)
    }) {
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
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func update(
        isEnabled: Bool,
        workspaceId: UUID?,
        panelId: UUID?,
        ttyName: String?,
        force: Bool = false
    ) {
        let normalizedTTY = ttyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled,
              let workspaceId,
              let panelId,
              let normalizedTTY,
              !normalizedTTY.isEmpty else {
            stopDetection(clearSession: true)
            return
        }

        let nextContext = Context(
            workspaceId: workspaceId,
            panelId: panelId,
            ttyName: TerminalSSHSessionDetector.normalizeTTYName(normalizedTTY)
        )
        guard force || context != nextContext else { return }

        context = nextContext
        detectionTask?.cancel()
        let detector = detector
        detectionTask = Task { [weak self] in
            let session = await TerminalSSHSessionDetector.detectAsync(
                forTTY: nextContext.ttyName,
                detector: detector
            )
            guard !Task.isCancelled, let self else { return }
            await self.record(session, for: nextContext)
        }
    }

    /// Invalidates the selected session without ending the observation stream.
    func stop() {
        stopDetection(clearSession: true)
    }

    private func record(_ session: DetectedSSHSession?, for expectedContext: Context) {
        guard context == expectedContext else { return }
        let nextSnapshot = Snapshot(
            workspaceId: expectedContext.workspaceId,
            panelId: expectedContext.panelId,
            ttyName: expectedContext.ttyName,
            session: session
        )
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot
        for continuation in continuations.values {
            continuation.yield(nextSnapshot)
        }
    }

    private func stopDetection(clearSession: Bool) {
        detectionTask?.cancel()
        detectionTask = nil
        context = nil
        guard clearSession, snapshot != nil else { return }
        snapshot = nil
        for continuation in continuations.values {
            continuation.yield(nil)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
