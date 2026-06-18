public import GhosttyKit

/// The Swift-side template for a new runtime surface's `ghostty_surface_config_s`.
///
/// Captures the inheritable startup inputs (font size, working directory,
/// command, environment, initial input) either empty for a fresh surface or
/// copied from a source surface's inherited C config when splitting.
public struct CmuxSurfaceConfigTemplate: Sendable {
    /// The font size in points; `0` means the runtime default.
    public var fontSize: Float32 = 0

    /// The working directory the spawned shell starts in.
    public var workingDirectory: String?

    /// The command to run instead of the default shell.
    public var command: String?

    /// Extra environment variables applied to the spawned process.
    public var environmentVariables: [String: String] = [:]

    /// Text written to the new surface immediately after spawn.
    public var initialInput: String?

    /// Whether the surface stays open after `command` exits.
    public var waitAfterCommand: Bool = false

    /// Creates an empty template (runtime defaults for every field).
    public init() {}

    /// Creates a template from a ghostty inherited surface config.
    ///
    /// - Parameter cConfig: The C config returned by
    ///   `ghostty_surface_inherited_config`.
    public init(cConfig: ghostty_surface_config_s) {
        fontSize = cConfig.font_size
        if let workingDirectory = cConfig.working_directory {
            self.workingDirectory = String(cString: workingDirectory, encoding: .utf8)
        }
        if let command = cConfig.command {
            self.command = String(cString: command, encoding: .utf8)
        }
        if let initialInput = cConfig.initial_input {
            self.initialInput = String(cString: initialInput, encoding: .utf8)
        }
        if cConfig.env_var_count > 0, let envVars = cConfig.env_vars {
            for index in 0..<Int(cConfig.env_var_count) {
                let envVar = envVars[index]
                if let key = String(cString: envVar.key, encoding: .utf8),
                   let value = String(cString: envVar.value, encoding: .utf8) {
                    environmentVariables[key] = value
                }
            }
        }
        waitAfterCommand = cConfig.wait_after_command
    }
}
