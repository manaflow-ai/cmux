public import Foundation

/// Selects whether a terminal surface created with a startup command outlives
/// that command.
public enum TerminalSurfaceCommandExitPolicy: Equatable, Sendable {
    /// Holds the PTY open once the startup command exits.
    case waitAfterCommand

    /// Closes the surface as soon as the startup command exits.
    case closeOnExit

    /// Applies the policy while preserving unrelated inherited configuration.
    ///
    /// - Parameter inheritedConfig: The configuration inherited from the
    ///   selected terminal, or `nil` when none is available.
    /// - Returns: The configuration for the new terminal.
    public func applying(
        to inheritedConfig: CmuxSurfaceConfigTemplate?
    ) -> CmuxSurfaceConfigTemplate {
        var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
        template.waitAfterCommand = self == .waitAfterCommand
        return template
    }
}
