import Foundation

/// One build command run at install/update time, mirroring herdr's `[[build]]`
/// manifest section: an argv array executed from the extension root, shown in
/// the consent preview before anything runs.
///
/// Build steps never run for linked (local development) extensions and never
/// receive cmux runtime/socket environment variables.
public struct DockExtensionBuildStep: Equatable, Sendable {
    /// The command as an argv array; the first element is the program.
    public let command: [String]

    /// Optional platform allowlist for this step; `nil` means every platform.
    public let platforms: [String]?

    /// Memberwise initializer, primarily for tests; production steps come from
    /// manifest parsing.
    public init(command: [String], platforms: [String]? = nil) {
        self.command = command
        self.platforms = platforms
    }
}
