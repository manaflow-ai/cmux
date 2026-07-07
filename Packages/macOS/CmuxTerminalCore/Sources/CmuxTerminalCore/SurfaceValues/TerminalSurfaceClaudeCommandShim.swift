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

    /// The sibling `codex` wrapper shim installed in the same per-surface
    /// directory, if the bundled `cmux-codex-wrapper` was available. Carried
    /// alongside the claude shim so the runtime surface creation can export
    /// `CMUX_CODEX_WRAPPER_SHIM` into the managed terminal environment (the
    /// same way it exports `CMUX_CLAUDE_WRAPPER_SHIM`), which a resumed codex
    /// session needs to route its `codex resume` through the wrapper and keep
    /// cmux hooks. `nil` when the codex wrapper was absent.
    public let codexCommandShim: TerminalSurfaceCodexCommandShim?

    /// Creates a shim descriptor.
    ///
    /// - Parameters:
    ///   - directoryPath: The per-surface shim directory prepended to `PATH`.
    ///   - executablePath: The executable shim script inside the directory.
    ///   - codexCommandShim: The sibling codex wrapper shim, if installed.
    public init(
        directoryPath: String,
        executablePath: String,
        codexCommandShim: TerminalSurfaceCodexCommandShim? = nil
    ) {
        self.directoryPath = directoryPath
        self.executablePath = executablePath
        self.codexCommandShim = codexCommandShim
    }
}
