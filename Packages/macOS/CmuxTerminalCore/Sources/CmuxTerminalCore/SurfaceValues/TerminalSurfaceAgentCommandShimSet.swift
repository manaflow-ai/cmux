/// The agent command shims installed for one terminal surface.
public struct TerminalSurfaceAgentCommandShimSet: Equatable, Sendable {
    /// The per-surface directory prepended to the spawned shell's `PATH`.
    public let directoryPath: String

    /// Every agent shim successfully installed in ``directoryPath``.
    public let shims: [TerminalSurfaceAgentCommandShim]

    /// Creates a per-surface agent command-shim set.
    ///
    /// - Parameters:
    ///   - directoryPath: The per-surface directory prepended to `PATH`.
    ///   - shims: The agent shims installed in the directory.
    public init(directoryPath: String, shims: [TerminalSurfaceAgentCommandShim]) {
        self.directoryPath = directoryPath
        self.shims = shims
    }

    /// Returns the installed shim for an agent command.
    ///
    /// - Parameter commandName: The command name to find, such as `hermes`.
    /// - Returns: The matching shim, or `nil` when its wrapper was unavailable.
    public func shim(named commandName: String) -> TerminalSurfaceAgentCommandShim? {
        shims.first { $0.commandName == commandName }
    }
}
