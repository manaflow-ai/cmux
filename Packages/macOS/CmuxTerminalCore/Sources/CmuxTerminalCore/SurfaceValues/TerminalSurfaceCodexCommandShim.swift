/// The on-disk `codex` wrapper shim installed for one terminal surface.
///
/// The shim lives in the same per-surface directory as the `claude` shim, which
/// is already prepended to the spawned shell's `PATH`, so `codex` resolves to
/// the cmux codex wrapper; both paths are exported to the shell as
/// `CMUX_CODEX_WRAPPER_SHIM` / `CMUX_CODEX_WRAPPER_SHIM_ROOT`.
public struct TerminalSurfaceCodexCommandShim: Equatable, Sendable {
    /// The per-surface shim directory (shared with the claude shim).
    public let directoryPath: String

    /// The executable shim script inside ``directoryPath``.
    public let executablePath: String

    /// Creates a shim descriptor.
    ///
    /// - Parameters:
    ///   - directoryPath: The per-surface shim directory.
    ///   - executablePath: The executable shim script inside the directory.
    public init(directoryPath: String, executablePath: String) {
        self.directoryPath = directoryPath
        self.executablePath = executablePath
    }
}
