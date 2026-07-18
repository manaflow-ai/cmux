internal import CmuxFoundation
public import GhosttyKit

/// The Swift-side template for a new runtime surface's `ghostty_surface_config_s`.
///
/// Captures the inheritable startup inputs (font size, working directory,
/// command, environment, initial input) either empty for a fresh surface or
/// copied from a source surface's inherited C config when splitting.
public struct CmuxSurfaceConfigTemplate: Sendable {
    /// The unscaled base font size in points; `0` means the runtime default.
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
    /// - Parameters:
    ///   - cConfig: The C config returned by `ghostty_surface_inherited_config`.
    ///   - globalFontMagnificationPercent: The magnification percent that was
    ///     applied to the runtime font size. The default keeps package parsing
    ///     deterministic at 100%.
    public init(
        cConfig: ghostty_surface_config_s,
        globalFontMagnificationPercent: Int = 100
    ) {
        fontSize = Self.baseFontSize(
            fromRuntimePoints: cConfig.font_size,
            percent: globalFontMagnificationPercent
        )
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

    /// Converts a runtime Ghostty font size back into an unscaled base point size
    /// at 100% magnification.
    ///
    /// - Parameter runtimePoints: The current runtime point size reported by Ghostty.
    /// - Returns: The corresponding base point size at 100% magnification.
    public static func baseFontSize(fromRuntimePoints runtimePoints: Float32) -> Float32 {
        baseFontSize(fromRuntimePoints: runtimePoints, percent: GlobalFontMagnification.defaultPercent)
    }

    /// Converts a runtime Ghostty font size back into an unscaled base point size.
    ///
    /// - Parameters:
    ///   - runtimePoints: The current runtime point size reported by Ghostty.
    ///   - percent: The global magnification percent used for the conversion.
    /// - Returns: The corresponding base point size for `percent`.
    public static func baseFontSize(fromRuntimePoints runtimePoints: Float32, percent: Int) -> Float32 {
        guard runtimePoints.isFinite, runtimePoints > 0 else { return runtimePoints }
        let scale = Float32(GlobalFontMagnification.scale(for: percent))
        guard scale > 0 else { return runtimePoints }
        return max(1, runtimePoints / scale)
    }

    /// Converts an unscaled base font size into the runtime point size Ghostty
    /// expects at 100% magnification.
    ///
    /// - Parameter basePoints: The unscaled base point size.
    /// - Returns: The runtime point size at 100% magnification.
    public static func runtimeFontSize(fromBasePoints basePoints: Float32) -> Float32 {
        runtimeFontSize(fromBasePoints: basePoints, percent: GlobalFontMagnification.defaultPercent)
    }

    /// Converts an unscaled base font size into the runtime point size Ghostty expects.
    ///
    /// - Parameters:
    ///   - basePoints: The unscaled base point size.
    ///   - percent: The global magnification percent used for the conversion.
    /// - Returns: The runtime point size for `percent`.
    public static func runtimeFontSize(fromBasePoints basePoints: Float32, percent: Int) -> Float32 {
        guard basePoints.isFinite, basePoints > 0 else { return basePoints }
        return max(1, basePoints * Float32(GlobalFontMagnification.scale(for: percent)))
    }
}
