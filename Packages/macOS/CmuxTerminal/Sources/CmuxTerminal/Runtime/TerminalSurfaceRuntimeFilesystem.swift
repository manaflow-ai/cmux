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
    /// hits a warm lookup (#21260).
    ///
    /// - Returns: Whether the directory opened. A directory that did not open
    ///   is not passed to Ghostty, which would otherwise retry it on main.
    public let prepareWorkingDirectory: @Sendable (_ path: String) async -> Bool

    private static let workingDirectoryOpenQueue = DispatchQueue(
        label: "com.cmuxterm.terminal.working-directory-open",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Opens and closes a directory on a dedicated queue, so a stalled lookup
    /// never parks a Swift concurrency pool thread.
    public static let openWorkingDirectory: @Sendable (_ path: String) async -> Bool = { path in
        await withCheckedContinuation { continuation in
            workingDirectoryOpenQueue.async {
                let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                if descriptor >= 0 {
                    close(descriptor)
                }
                continuation.resume(returning: descriptor >= 0)
            }
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
        prepareWorkingDirectory: @escaping @Sendable (_ path: String) async -> Bool =
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
        prepareWorkingDirectory: @escaping @Sendable (_ path: String) async -> Bool =
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
