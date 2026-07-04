import Foundation

/// Everything the app-side Dock bridge needs to open one extension pane as a
/// Dock terminal tab. Built by `DockExtensionsStore.openPane(...)`; consumed
/// by the app target's ``DockExtensionsHost`` implementation, which feeds it
/// into the Dock's login-shell terminal spawn path.
public struct DockExtensionPaneOpenRequest: Equatable, Sendable {
    /// Qualified `<extensionId>.<paneId>` id, exported as
    /// `CMUX_DOCK_CONTROL_ID` like config-seeded dock controls.
    public let controlId: String

    /// Tab title.
    public let title: String

    /// SF Symbol for the Dock tab.
    public let iconSystemName: String

    /// The pane argv rendered as one shell command string (see
    /// ``DockExtensionCommandLine``) for the Dock's login-shell wrapper.
    public let shellCommand: String

    /// Absolute working directory (extension root plus the pane's `cwd`).
    public let workingDirectory: String

    /// Pane environment: manifest `env` merged under the `CMUX_EXTENSION_*`
    /// context variables (cmux's values win).
    public let environment: [String: String]

    /// Creates an open request.
    public init(
        controlId: String,
        title: String,
        iconSystemName: String,
        shellCommand: String,
        workingDirectory: String,
        environment: [String: String]
    ) {
        self.controlId = controlId
        self.title = title
        self.iconSystemName = iconSystemName
        self.shellCommand = shellCommand
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}
