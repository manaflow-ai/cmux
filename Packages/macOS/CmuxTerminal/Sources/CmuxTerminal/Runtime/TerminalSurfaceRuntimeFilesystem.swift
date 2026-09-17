public import CmuxTerminalCore
public import Foundation
internal import os

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
        @Sendable (_ shims: TerminalSurfaceAgentCommandShimSet) async throws -> Void

    /// Reports the final error after bounded shim removal attempts fail.
    public let reportAgentCommandShimRemovalFailure:
        @Sendable (_ shims: TerminalSurfaceAgentCommandShimSet, _ errorDescription: String) -> Void

    /// Maximum removal attempts made by one lease release operation.
    public let agentCommandShimRemovalAttemptLimit: Int

    /// Returns whether the path points at an executable file.
    public let isExecutableFile: @Sendable (_ path: String) -> Bool

    /// Returns whether the path points at a directory.
    public let directoryExists: @Sendable (_ path: String) -> Bool

    /// Shared ownership gate for installs that can outlive a launch deadline.
    public let agentCommandShimInstallGate: TerminalSurfaceCommandShimInstallGate

    let agentCommandShimRemovalLane: TerminalSurfaceAgentCommandShimRemovalLane
    private let agentCommandShimCleanupOwner: TerminalSurfaceAgentCommandShimCleanupOwner

    /// Creates the runtime filesystem seam.
    public init(
        agentCommandShimTemporaryDirectory: URL,
        installAgentCommandShims:
        @escaping @Sendable (_ wrapperDirectoryURL: URL, _ surfaceId: UUID, _ temporaryDirectory: URL) async -> TerminalSurfaceAgentCommandShimSet?,
        removeAgentCommandShims:
        @escaping @Sendable (_ shims: TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportAgentCommandShimRemovalFailure:
        (@Sendable (_ shims: TerminalSurfaceAgentCommandShimSet, _ errorDescription: String) -> Void)? = nil,
        agentCommandShimRemovalAttemptLimit: Int = 3,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        directoryExists: @escaping @Sendable (_ path: String) -> Bool,
        agentCommandShimInstallGate: TerminalSurfaceCommandShimInstallGate = .init()
    ) {
        let removalAttemptLimit = max(1, agentCommandShimRemovalAttemptLimit)
        let removalLane = TerminalSurfaceAgentCommandShimRemovalLane()
        let removalFailureReporter =
            reportAgentCommandShimRemovalFailure ?? { shims, errorDescription in
                Logger(
                    subsystem: "com.cmuxterm.app",
                    category: "agent-command-shims"
                ).error(
                    "Failed to remove command shims at \(shims.directoryPath, privacy: .public): \(errorDescription, privacy: .public)"
                )
            }
        self.agentCommandShimTemporaryDirectory = agentCommandShimTemporaryDirectory
        self.installAgentCommandShims = installAgentCommandShims
        self.removeAgentCommandShims = removeAgentCommandShims
        self.reportAgentCommandShimRemovalFailure = removalFailureReporter
        self.agentCommandShimRemovalAttemptLimit = removalAttemptLimit
        agentCommandShimRemovalLane = removalLane
        agentCommandShimCleanupOwner = TerminalSurfaceAgentCommandShimCleanupOwner(
            removalAttemptLimit: removalAttemptLimit,
            removalLane: removalLane,
            remove: removeAgentCommandShims,
            reportRemovalFailure: removalFailureReporter
        )
        self.isExecutableFile = isExecutableFile
        self.directoryExists = directoryExists
        self.agentCommandShimInstallGate = agentCommandShimInstallGate
    }

    func cleanupUnownedAgentCommandShims(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        retryClock: any Clock<Duration>
    ) async {
        await agentCommandShimCleanupOwner.cleanup(shims, retryClock: retryClock)
    }

    func adoptUnownedAgentCommandShims(
        _ shims: TerminalSurfaceAgentCommandShimSet
    ) async {
        _ = await agentCommandShimCleanupOwner.adopt(shims)
    }

    func prepareAgentCommandShimInstall(
        retryClock: any Clock<Duration>
    ) async -> Bool {
        // New shim directories stop at the cleanup ownership boundary until a
        // bounded sweep removes every previously failed directory.
        await agentCommandShimCleanupOwner.prepareForInstall(retryClock: retryClock)
    }
}
