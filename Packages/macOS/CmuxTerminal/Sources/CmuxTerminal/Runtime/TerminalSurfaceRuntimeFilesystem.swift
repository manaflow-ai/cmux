public import Foundation
public import CmuxTerminalCore

/// Limits command-shim installation to one live operation per runtime
/// filesystem owner, including an installer that does not stop on cancellation.
public final class TerminalSurfaceCommandShimInstallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeToken: UUID?

    /// Creates an idle install gate.
    public init() {}

    func claim() -> UUID? {
        lock.withLock {
            guard activeToken == nil else { return nil }
            let token = UUID()
            activeToken = token
            return token
        }
    }

    func release(_ token: UUID) {
        lock.withLock {
            guard activeToken == token else { return }
            activeToken = nil
        }
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
