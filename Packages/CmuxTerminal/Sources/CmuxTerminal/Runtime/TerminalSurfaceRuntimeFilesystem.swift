public import Foundation
public import CmuxTerminalCore

/// Filesystem operations injected into ``TerminalSurface`` runtime creation.
public struct TerminalSurfaceRuntimeFilesystem: Sendable {
    /// The root directory used for per-surface Claude command shims.
    public let claudeCommandShimTemporaryDirectory: URL

    /// Installs a per-surface Claude command shim when the bundled wrapper is available.
    public let installClaudeCommandShim:
        @Sendable (_ wrapperURL: URL, _ surfaceId: UUID, _ temporaryDirectory: URL) async -> TerminalSurfaceClaudeCommandShim?

    /// Returns whether the path points at an executable file.
    public let isExecutableFile: @Sendable (_ path: String) -> Bool

    /// Creates the runtime filesystem seam.
    public init(
        claudeCommandShimTemporaryDirectory: URL,
        installClaudeCommandShim:
            @escaping @Sendable (_ wrapperURL: URL, _ surfaceId: UUID, _ temporaryDirectory: URL) async -> TerminalSurfaceClaudeCommandShim?,
        isExecutableFile: @escaping @Sendable (_ path: String) -> Bool
    ) {
        self.claudeCommandShimTemporaryDirectory = claudeCommandShimTemporaryDirectory
        self.installClaudeCommandShim = installClaudeCommandShim
        self.isExecutableFile = isExecutableFile
    }
}
