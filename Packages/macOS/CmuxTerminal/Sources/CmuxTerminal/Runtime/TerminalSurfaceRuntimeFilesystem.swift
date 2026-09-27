public import Foundation
public import CmuxTerminalCore

/// Filesystem operations injected into ``TerminalSurface`` runtime creation.
public struct TerminalSurfaceRuntimeFilesystem: Sendable {
    /// The root directory used for per-surface agent command shims.
    public let agentCommandShimTemporaryDirectory: URL

    /// Installs per-surface agent command shims for the available bundled wrappers.
    public let installAgentCommandShims:
        @Sendable (
            _ wrapperDirectoryURL: URL,
            _ surfaceId: UUID,
            _ temporaryDirectory: URL,
            _ enabledCommands: Set<TerminalSurfaceAgentCommand>
        ) async -> TerminalSurfaceAgentCommandShimSet?

    /// Returns whether the path points at an executable file.
    public let isExecutableFile: @Sendable (_ path: String) -> Bool

    /// Creates the runtime filesystem seam with a policy-aware shim installer.
    public init(
        agentCommandShimTemporaryDirectory: URL,
        installAgentCommandShims:
            @escaping @Sendable (
                _ wrapperDirectoryURL: URL,
                _ surfaceId: UUID,
                _ temporaryDirectory: URL,
                _ enabledCommands: Set<TerminalSurfaceAgentCommand>
            ) async -> TerminalSurfaceAgentCommandShimSet?,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool
    ) {
        self.agentCommandShimTemporaryDirectory = agentCommandShimTemporaryDirectory
        self.installAgentCommandShims = installAgentCommandShims
        self.isExecutableFile = isExecutableFile
    }

    /// Creates the runtime filesystem seam with an installer that ignores
    /// command selection. This keeps existing tests and embedders source-compatible.
    public init(
        agentCommandShimTemporaryDirectory: URL,
        installAgentCommandShims:
            @escaping @Sendable (
                _ wrapperDirectoryURL: URL,
                _ surfaceId: UUID,
                _ temporaryDirectory: URL
            ) async -> TerminalSurfaceAgentCommandShimSet?,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool
    ) {
        self.init(
            agentCommandShimTemporaryDirectory: agentCommandShimTemporaryDirectory,
            installAgentCommandShims: { wrapperDirectoryURL, surfaceId, temporaryDirectory, _ in
                await installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory
                )
            },
            isExecutableFile: isExecutableFile
        )
    }
}
