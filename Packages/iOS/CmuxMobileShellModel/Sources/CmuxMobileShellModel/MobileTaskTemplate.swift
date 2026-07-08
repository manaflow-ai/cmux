public import Foundation

/// A user-editable template for creating a new mobile task workspace.
public struct MobileTaskTemplate: Codable, Equatable, Sendable, Identifiable {
    /// Stable template identifier.
    public var id: UUID
    /// User-visible template name.
    public var name: String
    /// SF Symbol name or single emoji used to represent the template.
    public var icon: String
    /// Shell script run in the new workspace's first terminal.
    public var command: String
    /// Optional default working directory for workspaces created from this template.
    public var defaultDirectory: String?

    /// Creates a mobile task template.
    /// - Parameters:
    ///   - id: Stable template identifier.
    ///   - name: User-visible template name.
    ///   - icon: SF Symbol name or single emoji.
    ///   - command: Shell script run in the first terminal.
    ///   - defaultDirectory: Optional default working directory.
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        command: String,
        defaultDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.command = command
        self.defaultDirectory = defaultDirectory
    }

    /// Default templates written once into the device-local template store.
    /// Display names are passed in: they are user-facing, and localization
    /// lives at the store/UI boundary, not in this model package.
    /// - Parameters:
    ///   - claudeName: Localized name for the Claude template.
    ///   - codexName: Localized name for the Codex template.
    ///   - shellName: Localized name for the plain-shell template.
    public static func seedDefaults(
        claudeName: String,
        codexName: String,
        shellName: String
    ) -> [MobileTaskTemplate] {
        [
            MobileTaskTemplate(name: claudeName, icon: "brain.head.profile", command: "claude"),
            MobileTaskTemplate(name: codexName, icon: "sparkles", command: "codex"),
            MobileTaskTemplate(name: shellName, icon: "terminal", command: ""),
        ]
    }
}
