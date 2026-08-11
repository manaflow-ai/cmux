public import Foundation
public import CmuxTerminalCore

/// Limits command-shim installation to one live operation per runtime
/// filesystem owner, including an installer that does not stop on cancellation.
public final class TerminalSurfaceCommandShimInstallGate: @unchecked Sendable {
    private final class Acquisition: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var isCompleted = false
        private var cancellationHandler: (@Sendable () -> Void)?

        func installCancellationHandler(
            _ handler: @escaping @Sendable () -> Void
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else { return false }
            guard !isCancelled else {
                isCompleted = true
                return false
            }
            cancellationHandler = handler
            return true
        }

        func cancel() {
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCancelled = true
            let handler = cancellationHandler
            lock.unlock()
            handler?()
        }

        func completeWithPermit() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else { return false }
            isCompleted = true
            cancellationHandler = nil
            return !isCancelled
        }

        func completeAfterCancellation() {
            lock.lock()
            isCompleted = true
            cancellationHandler = nil
            lock.unlock()
        }
    }

    private struct Waiter {
        let acquisition: Acquisition
        let continuation: CheckedContinuation<UUID?, Never>
    }

    private let lock = NSLock()
    private var activeToken: UUID?
    private var waiters: [Waiter] = []

    /// Creates an idle install gate.
    public init() {}

    func acquire() async -> UUID? {
        let acquisition = Acquisition()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(acquisition: acquisition, continuation: continuation)
            }
        } onCancel: {
            acquisition.cancel()
        }
    }

    func release(_ token: UUID) {
        var cancelledContinuations: [CheckedContinuation<UUID?, Never>] = []
        var granted: (CheckedContinuation<UUID?, Never>, UUID)?
        lock.lock()
        guard activeToken == token else {
            lock.unlock()
            return
        }
        activeToken = nil
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            guard waiter.acquisition.completeWithPermit() else {
                cancelledContinuations.append(waiter.continuation)
                continue
            }
            let nextToken = UUID()
            activeToken = nextToken
            granted = (waiter.continuation, nextToken)
            break
        }
        lock.unlock()

        for continuation in cancelledContinuations {
            continuation.resume(returning: nil)
        }
        if let granted {
            granted.0.resume(returning: granted.1)
        }
    }

    private func enqueue(
        acquisition: Acquisition,
        continuation: CheckedContinuation<UUID?, Never>
    ) {
        lock.lock()
        if activeToken == nil {
            let token = UUID()
            activeToken = token
            lock.unlock()
            guard acquisition.completeWithPermit() else {
                release(token)
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: token)
            return
        }

        waiters.append(Waiter(acquisition: acquisition, continuation: continuation))
        let installed = acquisition.installCancellationHandler { [weak self, weak acquisition] in
            guard let self, let acquisition else { return }
            self.cancel(acquisition)
        }
        guard installed else {
            waiters.removeAll { $0.acquisition === acquisition }
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        lock.unlock()
    }

    private func cancel(_ acquisition: Acquisition) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.acquisition === acquisition }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        acquisition.completeAfterCancellation()
        waiter.continuation.resume(returning: nil)
    }
}

/// Filesystem operations injected into ``TerminalSurface`` runtime creation.
public struct TerminalSurfaceRuntimeFilesystem: Sendable {
    /// The root directory used for per-surface agent command shims.
    public let agentCommandShimTemporaryDirectory: URL

    /// Installs per-surface agent command shims for the available bundled wrappers.
    ///
    /// The operation should observe task cancellation and return promptly. Launch
    /// resolution can return at its deadline without waiting for acknowledgement.
    public let installAgentCommandShims:
        @Sendable (_ wrapperDirectoryURL: URL, _ surfaceId: UUID, _ temporaryDirectory: URL) async -> TerminalSurfaceAgentCommandShimSet?

    /// Returns whether the path points at an executable file.
    public let isExecutableFile: @Sendable (_ path: String) -> Bool

    /// Shared ownership gate for installs that can outlive a launch deadline.
    public let agentCommandShimInstallGate: TerminalSurfaceCommandShimInstallGate

    /// Creates the runtime filesystem seam.
    public init(
        agentCommandShimTemporaryDirectory: URL,
        installAgentCommandShims:
            @escaping @Sendable (_ wrapperDirectoryURL: URL, _ surfaceId: UUID, _ temporaryDirectory: URL) async -> TerminalSurfaceAgentCommandShimSet?,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        agentCommandShimInstallGate: TerminalSurfaceCommandShimInstallGate = .init()
    ) {
        self.agentCommandShimTemporaryDirectory = agentCommandShimTemporaryDirectory
        self.installAgentCommandShims = installAgentCommandShims
        self.isExecutableFile = isExecutableFile
        self.agentCommandShimInstallGate = agentCommandShimInstallGate
    }
}
