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

    /// Prefix marking an icon value as a bundled agent brand image rather
    /// than an SF Symbol or emoji (e.g. `agent:claude`).
    public static let agentIconPrefix = "agent:"

    /// Returns the bundled brand-image base name for an `agent:` icon value,
    /// or nil when the value is a symbol/emoji icon. These resolve to loose
    /// PNGs in the UI package (AgentIcons/<Name>@3x.png), NOT an asset
    /// catalog: dev reloads override PRODUCT_BUNDLE_IDENTIFIER globally,
    /// which stamps SwiftPM resource bundles with the app's identifier and
    /// breaks CoreUI catalog registration (Image(named:) then fails even
    /// though the compiled Assets.car contains the entries).
    public static func agentIconAssetName(for icon: String) -> String? {
        guard icon.hasPrefix(agentIconPrefix) else { return nil }
        switch icon.dropFirst(agentIconPrefix.count) {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        default: return nil
        }
    }

    /// Default templates written once into the device-local template store.
    /// Display names are passed in: they are user-facing, and localization
    /// lives at the store/UI boundary, not in this model package.
    /// - Parameters:
    ///   - claudeName: Localized name for the Claude template.
    ///   - codexName: Localized name for the Codex template.
    ///   - openCodeName: Localized name for the OpenCode template.
    ///   - shellName: Localized name for the plain-shell template.
    public static func seedDefaults(
        claudeName: String,
        codexName: String,
        openCodeName: String,
        shellName: String
    ) -> [MobileTaskTemplate] {
        [
            MobileTaskTemplate(name: claudeName, icon: "agent:claude", command: "claude"),
            MobileTaskTemplate(name: codexName, icon: "agent:codex", command: "codex"),
            MobileTaskTemplate(name: openCodeName, icon: "agent:opencode", command: "opencode"),
            MobileTaskTemplate(name: shellName, icon: "terminal", command: ""),
        ]
    }
}
