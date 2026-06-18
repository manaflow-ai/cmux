/// The on-disk `claude` wrapper shim installed for one terminal surface.
///
/// The shim directory is prepended to the spawned shell's `PATH` so `claude`
/// resolves to the cmux wrapper; both paths are exported to the shell as
/// `CMUX_CLAUDE_WRAPPER_SHIM` / `CMUX_CLAUDE_WRAPPER_SHIM_ROOT`.
public struct TerminalSurfaceClaudeCommandShim: Equatable, Sendable {
    /// The per-surface shim directory prepended to `PATH`.
    public let directoryPath: String

    /// The executable shim script inside ``directoryPath``.
    public let executablePath: String

    /// Creates a shim descriptor.
    ///
    /// - Parameters:
    ///   - directoryPath: The per-surface shim directory prepended to `PATH`.
    ///   - executablePath: The executable shim script inside the directory.
    public init(directoryPath: String, executablePath: String) {
        self.directoryPath = directoryPath
        self.executablePath = executablePath
    }
}
