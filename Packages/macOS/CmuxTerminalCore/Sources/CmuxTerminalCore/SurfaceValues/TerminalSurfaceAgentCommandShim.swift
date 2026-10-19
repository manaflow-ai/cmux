/// An on-disk command shim installed for one agent in a terminal surface.
///
/// The executable lives in a per-surface directory prepended to `PATH` and
/// routes the agent command through its bundled cmux launch wrapper.
public struct TerminalSurfaceAgentCommandShim: Equatable, Sendable {
    /// The command intercepted on `PATH`, such as `claude`, `codex`, or `hermes`.
    public let commandName: String

    /// The bundled cmux wrapper executable used by the shim.
    public let wrapperName: String

    /// The prefix for the wrapper's `_WRAPPER_SHIM` environment keys.
    public let environmentVariablePrefix: String

    /// The per-surface shim directory prepended to `PATH`.
    public let directoryPath: String

    /// The executable shim script inside ``directoryPath``.
    public let executablePath: String

    /// The environment key containing ``executablePath``.
    public var wrapperShimEnvironmentKey: String {
        "\(environmentVariablePrefix)_WRAPPER_SHIM"
    }

    /// The environment key containing ``directoryPath``.
    public var wrapperShimRootEnvironmentKey: String {
        "\(environmentVariablePrefix)_WRAPPER_SHIM_ROOT"
    }

    /// Creates an agent command-shim descriptor.
    ///
    /// - Parameters:
    ///   - commandName: The command intercepted on `PATH`.
    ///   - wrapperName: The bundled cmux wrapper executable.
    ///   - environmentVariablePrefix: The prefix for wrapper-shim environment keys.
    ///   - directoryPath: The shared per-surface shim directory.
    ///   - executablePath: The executable shim script.
    public init(
        commandName: String,
        wrapperName: String,
        environmentVariablePrefix: String,
        directoryPath: String,
        executablePath: String
    ) {
        self.commandName = commandName
        self.wrapperName = wrapperName
        self.environmentVariablePrefix = environmentVariablePrefix
        self.directoryPath = directoryPath
        self.executablePath = executablePath
    }
}
