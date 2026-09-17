public import CmuxTerminalCore
internal import Foundation

/// Owns a best-effort shim install without making terminal launch wait for a
/// filesystem operation to acknowledge cancellation. The installer is asked
/// to stop at the injected deadline, but this owner can publish `nil` first and
/// release launch even when an OS filesystem call returns late.
actor TerminalSurfaceCommandShimInstallAttempt {
    private let filesystem: TerminalSurfaceRuntimeFilesystem
    private let wrapperDirectoryURL: URL
    private let surfaceID: UUID
    private let deadline: Duration
    private let clock: any Clock<Duration>
    private let installLease: TerminalSurfaceCommandShimInstallLease
    private var isStarted = false
    private var isResolved = false
    private var resolvedShims: TerminalSurfaceAgentCommandShimSet?
    private var continuation:
        CheckedContinuation<TerminalSurfaceAgentCommandShimSet?, Never>?
    private var installTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(
        filesystem: TerminalSurfaceRuntimeFilesystem,
        wrapperDirectoryURL: URL,
        surfaceID: UUID,
        deadline: Duration,
        clock: any Clock<Duration>
    ) {
        self.filesystem = filesystem
        self.wrapperDirectoryURL = wrapperDirectoryURL
        self.surfaceID = surfaceID
        self.deadline = deadline
        self.clock = clock
        installLease = TerminalSurfaceCommandShimInstallLease(
            gate: filesystem.agentCommandShimInstallGate
        )
    }

    func value() async -> TerminalSurfaceAgentCommandShimSet? {
        startIfNeeded()
        if isResolved {
            return resolvedShims
        }
        return await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    func cancel() async {
        _ = await resolve(nil, invalidatingInstall: true)
    }

    private func startIfNeeded() {
        guard !isStarted, !isResolved else { return }
        isStarted = true
        let filesystem = filesystem
        let wrapperDirectoryURL = wrapperDirectoryURL
        let surfaceID = surfaceID
        let clock = clock
        let deadline = deadline
        let installLease = installLease
        installTask = Task.detached(priority: .utility) { [weak self] in
            guard let installToken = await installLease.acquire() else {
                await self?.resolve(nil)
                return
            }
            guard !Task.isCancelled else {
                await installLease.release(installToken)
                return
            }
            guard await filesystem.prepareAgentCommandShimInstall(
                retryClock: clock
            ) else {
                await installLease.release(installToken)
                await self?.resolve(nil)
                return
            }
            guard !Task.isCancelled else {
                await installLease.release(installToken)
                return
            }
            let shims = await filesystem.installAgentCommandShims(
                wrapperDirectoryURL,
                surfaceID,
                filesystem.agentCommandShimTemporaryDirectory
            )
            let accepted = await self?.resolve(shims) == true
            if !accepted, let shims {
                await filesystem.adoptUnownedAgentCommandShims(shims)
            }
            await installLease.release(installToken)
            if !accepted, let shims {
                await filesystem.cleanupUnownedAgentCommandShims(shims, retryClock: clock)
            }
        }
        deadlineTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await clock.sleep(for: deadline, tolerance: nil)
            } catch {
                return
            }
            await self?.resolve(nil, invalidatingInstall: true)
        }
    }

    @discardableResult
    private func resolve(
        _ shims: TerminalSurfaceAgentCommandShimSet?,
        invalidatingInstall: Bool = false
    ) async -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        resolvedShims = shims
        let continuation = continuation
        self.continuation = nil
        let installTask = installTask
        self.installTask = nil
        let deadlineTask = deadlineTask
        self.deadlineTask = nil

        if invalidatingInstall {
            await installLease.invalidate()
        }
        installTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(returning: shims)
        return true
    }
}
