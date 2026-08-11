public import Foundation
public import CmuxTerminalCore

/// Limits command-shim installation to one live operation per runtime
/// filesystem owner, including an installer that does not stop on cancellation.
/// After an active deadline expires, new work is rejected until that installer
/// returns and releases its filesystem ownership.
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

    private final class Waiter {
        let acquisition: Acquisition
        let continuation: CheckedContinuation<UUID?, Never>
        weak var previous: Waiter?
        var next: Waiter?

        init(
            acquisition: Acquisition,
            continuation: CheckedContinuation<UUID?, Never>
        ) {
            self.acquisition = acquisition
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let maximumWaiterCount: Int
    private var activeToken: UUID?
    private var waiterHead: Waiter?
    private var waiterTail: Waiter?
    private var waiters: [ObjectIdentifier: Waiter] = [:]
    private var rejectsAcquisitionsUntilRelease = false

    /// Creates an idle install gate with a fixed pending-work limit.
    ///
    /// - Parameter maximumWaiterCount: The maximum number of installs that can
    ///   wait behind the active installer. A nonpositive value disables
    ///   waiting, and additional work is rejected.
    public init(maximumWaiterCount: Int = 64) {
        self.maximumWaiterCount = max(0, maximumWaiterCount)
    }

    func acquire() async -> UUID? {
        await acquire(onQueued: {})
    }

    func acquire(
        onQueued: @escaping @Sendable () -> Void
    ) async -> UUID? {
        let acquisition = Acquisition()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    acquisition: acquisition,
                    continuation: continuation,
                    onQueued: onQueued
                )
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
        if rejectsAcquisitionsUntilRelease {
            rejectsAcquisitionsUntilRelease = false
            lock.unlock()
            return
        }
        while let waiter = waiterHead {
            removeWaiterLocked(waiter)
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

    func rejectAcquisitions(untilReleaseOf token: UUID) {
        var rejectedContinuations: [CheckedContinuation<UUID?, Never>] = []
        lock.lock()
        guard activeToken == token else {
            lock.unlock()
            return
        }
        rejectsAcquisitionsUntilRelease = true
        while let waiter = waiterHead {
            removeWaiterLocked(waiter)
            waiter.acquisition.completeAfterCancellation()
            rejectedContinuations.append(waiter.continuation)
        }
        lock.unlock()

        for continuation in rejectedContinuations {
            continuation.resume(returning: nil)
        }
    }

    private func enqueue(
        acquisition: Acquisition,
        continuation: CheckedContinuation<UUID?, Never>,
        onQueued: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        if rejectsAcquisitionsUntilRelease {
            lock.unlock()
            acquisition.completeAfterCancellation()
            continuation.resume(returning: nil)
            return
        }
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

        guard waiters.count < maximumWaiterCount else {
            lock.unlock()
            acquisition.completeAfterCancellation()
            continuation.resume(returning: nil)
            return
        }
        let waiter = Waiter(
            acquisition: acquisition,
            continuation: continuation
        )
        appendWaiterLocked(waiter)
        let installed = acquisition.installCancellationHandler { [weak self, weak acquisition] in
            guard let self, let acquisition else { return }
            self.cancel(acquisition)
        }
        guard installed else {
            removeWaiterLocked(waiter)
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        lock.unlock()
        onQueued()
    }

    private func cancel(_ acquisition: Acquisition) {
        lock.lock()
        let identifier = ObjectIdentifier(acquisition)
        guard let waiter = waiters[identifier] else {
            lock.unlock()
            return
        }
        removeWaiterLocked(waiter)
        lock.unlock()
        acquisition.completeAfterCancellation()
        waiter.continuation.resume(returning: nil)
    }

    private func appendWaiterLocked(_ waiter: Waiter) {
        waiter.previous = waiterTail
        waiterTail?.next = waiter
        waiterTail = waiter
        if waiterHead == nil {
            waiterHead = waiter
        }
        waiters[ObjectIdentifier(waiter.acquisition)] = waiter
    }

    private func removeWaiterLocked(_ waiter: Waiter) {
        if let previous = waiter.previous {
            previous.next = waiter.next
        } else {
            waiterHead = waiter.next
        }
        if let next = waiter.next {
            next.previous = waiter.previous
        } else {
            waiterTail = waiter.previous
        }
        waiter.previous = nil
        waiter.next = nil
        waiters.removeValue(forKey: ObjectIdentifier(waiter.acquisition))
    }
}

final class TerminalSurfaceCommandShimInstallLease: @unchecked Sendable {
    private let gate: TerminalSurfaceCommandShimInstallGate
    private let lock = NSLock()
    private var isInvalidated = false
    private var token: UUID?

    init(gate: TerminalSurfaceCommandShimInstallGate) {
        self.gate = gate
    }

    func acquire() async -> UUID? {
        guard let token = await gate.acquire() else { return nil }
        guard publish(token) else {
            gate.release(token)
            return nil
        }
        return token
    }

    private func publish(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return false }
        self.token = token
        return true
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        let token = token
        lock.unlock()

        if let token {
            gate.rejectAcquisitions(untilReleaseOf: token)
        }
    }

    func release(_ token: UUID) {
        lock.lock()
        if self.token == token {
            self.token = nil
        }
        lock.unlock()
        gate.release(token)
    }
}

final class TerminalSurfaceCommandShimInstallResultGate: @unchecked Sendable {
    private enum State {
        case pending
        case accepted
        case expired
    }

    private let lock = NSLock()
    private var state = State.pending

    func acceptResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .accepted
        return true
    }

    func expire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .expired
        return true
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

    /// Removes a shim set that completed after its launch owner released it.
    public let removeAgentCommandShims:
        @Sendable (_ shims: TerminalSurfaceAgentCommandShimSet) async -> Void

    /// Returns whether the path points at an executable file.
    public let isExecutableFile: @Sendable (_ path: String) -> Bool

    /// Returns whether the path points at a directory.
    public let directoryExists: @Sendable (_ path: String) -> Bool

    /// Shared ownership gate for installs that can outlive a launch deadline.
    public let agentCommandShimInstallGate: TerminalSurfaceCommandShimInstallGate

    /// Creates the runtime filesystem seam.
    public init(
        agentCommandShimTemporaryDirectory: URL,
        installAgentCommandShims:
            @escaping @Sendable (_ wrapperDirectoryURL: URL, _ surfaceId: UUID, _ temporaryDirectory: URL) async -> TerminalSurfaceAgentCommandShimSet?,
        removeAgentCommandShims:
            @escaping @Sendable (_ shims: TerminalSurfaceAgentCommandShimSet) async -> Void = { shims in
                try? FileManager.default.removeItem(atPath: shims.directoryPath)
            },
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        directoryExists: @escaping @Sendable (_ path: String) -> Bool,
        agentCommandShimInstallGate: TerminalSurfaceCommandShimInstallGate = .init()
    ) {
        self.agentCommandShimTemporaryDirectory = agentCommandShimTemporaryDirectory
        self.installAgentCommandShims = installAgentCommandShims
        self.removeAgentCommandShims = removeAgentCommandShims
        self.isExecutableFile = isExecutableFile
        self.directoryExists = directoryExists
        self.agentCommandShimInstallGate = agentCommandShimInstallGate
    }
}
