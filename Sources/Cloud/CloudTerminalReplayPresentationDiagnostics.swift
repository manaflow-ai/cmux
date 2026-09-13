import CmuxTerminal
import Foundation

/// Observes display readiness independently of the healthy byte connection.
/// Each attachment records at most one visible replay result. Hidden panes
/// cancel this observation; they never time out or reconnect the transport.
@MainActor
final class CloudTerminalReplayPresentationDiagnostics {
    private let operations: CloudOperationRecorder?
    private let isVisible: @MainActor () -> Bool
    private let waitForDeadline: @Sendable () async throws -> Void
    private var receipt = TerminalManualOutputPresentation()
    private var completed = false
    private var root: CloudOperationContext?
    private var ready: CloudOperationContext?
    private var deadline: Task<Void, Never>?

    init(
        operations: CloudOperationRecorder?,
        isVisible: @escaping @MainActor () -> Bool,
        waitForDeadline: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(60))
        }
    ) {
        self.operations = operations
        self.isVisible = isVisible
        self.waitForDeadline = waitForDeadline
    }

    func reset() {
        finish(error: CancellationError())
        completed = false
        receipt = .init()
    }

    func receive(_ revision: UInt64?) {
        receipt = .init(expectedRevision: revision)
        observeIfNeeded()
    }

    func visibilityChanged(_ visible: Bool) {
        if visible { observeIfNeeded() }
        else { finish(error: CancellationError()) }
    }

    func presented(_ revision: UInt64) {
        guard receipt.acknowledge(revision), !completed else { return }
        observeIfNeeded()
        completed = true
        finish()
    }

    private func observeIfNeeded() {
        guard !completed, receipt.hasReplay, isVisible(), ready == nil,
              let operations else { return }
        let root = operations.begin(.terminal, foreground: false)
        let ready = operations.beginChild(of: root, phase: .ready, attempt: 0)
        self.root = root
        self.ready = ready
        let wait = waitForDeadline
        deadline = Task { @MainActor [weak self] in
            do { try await wait() } catch { return }
            guard !Task.isCancelled, let self, self.ready?.spanID == ready.spanID else { return }
            let visible = self.isVisible()
            self.completed = visible
            self.finish(error: visible ? CloudDiagnosticFailure.timeout : .cancelled)
        }
    }

    private func finish(error: Error? = nil) {
        deadline?.cancel()
        deadline = nil
        guard let root, let ready else { return }
        self.root = nil
        self.ready = nil
        Task {
            await ready.recorder.finish(ready, error: error)
            await root.recorder.finish(root, error: error)
        }
    }
}
