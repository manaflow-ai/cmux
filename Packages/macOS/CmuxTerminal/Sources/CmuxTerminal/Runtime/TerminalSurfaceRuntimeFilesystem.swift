public import Foundation
public import CmuxTerminalCore
internal import Darwin

/// Filesystem operations injected into ``TerminalSurface`` runtime creation.
public struct TerminalSurfaceRuntimeFilesystem: Sendable {
    /// The durable root directory used for per-surface agent command shims.
    public let agentCommandShimRootDirectory: URL

    /// Installs per-surface agent command shims for the available bundled wrappers.
    public let installAgentCommandShims:
        @Sendable (
            _ wrapperDirectoryURL: URL,
            _ surfaceId: UUID,
            _ rootDirectory: URL,
            _ enabledCommands: Set<TerminalSurfaceAgentCommand>
        ) async -> TerminalSurfaceAgentCommandShimSet?

    /// Returns whether the path points at an executable file.
    public let isExecutableFile: @Sendable (_ path: String) -> Bool

    /// Opens a runtime working directory before native surface creation.
    ///
    /// `ghostty_surface_new` opens the requested working directory on the
    /// calling thread. Opening it here first, off the main actor, absorbs a
    /// slow volume, File Provider or privacy check so the main-thread open
    /// hits a warm lookup (#21260). The result is advisory: Ghostty still
    /// decides whether the directory is usable.
    public let prepareWorkingDirectory: @Sendable (_ path: String) async -> Void

    /// Opens and closes a directory, blocking the calling thread until the
    /// kernel lookup completes.
    public static let openWorkingDirectory: @Sendable (_ path: String) async -> Void = { path in
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    /// Creates the runtime filesystem seam with a policy-aware shim installer.
    public init(
        agentCommandShimRootDirectory: URL,
        installAgentCommandShims:
            @escaping @Sendable (
                _ wrapperDirectoryURL: URL,
                _ surfaceId: UUID,
                _ rootDirectory: URL,
                _ enabledCommands: Set<TerminalSurfaceAgentCommand>
            ) async -> TerminalSurfaceAgentCommandShimSet?,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        prepareWorkingDirectory: @escaping @Sendable (_ path: String) async -> Void =
            TerminalSurfaceRuntimeFilesystem.openWorkingDirectory
    ) {
        self.agentCommandShimRootDirectory = agentCommandShimRootDirectory
        self.installAgentCommandShims = installAgentCommandShims
        self.isExecutableFile = isExecutableFile
        self.prepareWorkingDirectory = prepareWorkingDirectory
    }

    /// Creates the runtime filesystem seam with an installer that ignores
    /// command selection. This keeps existing tests and embedders source-compatible.
    public init(
        agentCommandShimRootDirectory: URL,
        installAgentCommandShims:
            @escaping @Sendable (
                _ wrapperDirectoryURL: URL,
                _ surfaceId: UUID,
                _ rootDirectory: URL
            ) async -> TerminalSurfaceAgentCommandShimSet?,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool,
        prepareWorkingDirectory: @escaping @Sendable (_ path: String) async -> Void =
            TerminalSurfaceRuntimeFilesystem.openWorkingDirectory
    ) {
        self.init(
            agentCommandShimRootDirectory: agentCommandShimRootDirectory,
            installAgentCommandShims: { wrapperDirectoryURL, surfaceId, rootDirectory, _ in
                await installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceId,
                    rootDirectory
                )
            },
            isExecutableFile: isExecutableFile,
            prepareWorkingDirectory: prepareWorkingDirectory
        )
    }
}
