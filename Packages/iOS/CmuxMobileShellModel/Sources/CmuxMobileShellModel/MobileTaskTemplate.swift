public import Foundation

/// Stable identity for one task template shipped by cmux.
public enum MobileTaskBuiltInTemplateKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case openCode
    case shell
}

/// A user-editable template for creating a new mobile task workspace.
public struct MobileTaskTemplate: Codable, Equatable, Sendable, Identifiable {
    /// Stable template identifier.
    public var id: UUID
    /// User-visible template name.
    public var name: String
    /// SF Symbol name or single emoji used to represent the template.
    public var icon: String
    /// Shell script run in the new workspace's first terminal. Empty or
    /// whitespace-only values create a plain shell.
    public var command: String
    /// Optional default working directory for workspaces created from this template.
    public var defaultDirectory: String?
    /// Whether this template ships with cmux and must remain available.
    public var isBuiltIn: Bool
    /// Stable shipped-template identity, retained when editable fields change.
    public var builtInKind: MobileTaskBuiltInTemplateKind?

    /// Whether the command is blank and should open a plain shell.
    public var isPlainShell: Bool {
        command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Creates a mobile task template.
    /// - Parameters:
    ///   - id: Stable template identifier.
    ///   - name: User-visible template name.
    ///   - icon: SF Symbol name or single emoji.
    ///   - command: Shell script run in the first terminal; blank values create a plain shell.
    ///   - defaultDirectory: Optional default working directory.
    ///   - isBuiltIn: Whether cmux owns this permanent template.
    ///   - builtInKind: Stable identity for a template shipped by cmux.
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        command: String,
        defaultDirectory: String? = nil,
        isBuiltIn: Bool = false,
        builtInKind: MobileTaskBuiltInTemplateKind? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.command = command
        self.defaultDirectory = defaultDirectory
        self.isBuiltIn = isBuiltIn || builtInKind != nil
        self.builtInKind = builtInKind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case command
        case defaultDirectory
        case isBuiltIn
        case builtInKind
    }

    /// Decodes templates written before built-in provenance was persisted.
    /// Legacy values remain custom until the store's one-time seed migration
    /// can classify them using the canonical shipped signatures.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        command = try container.decode(String.self, forKey: .command)
        defaultDirectory = try container.decodeIfPresent(
            String.self,
            forKey: .defaultDirectory
        )
        builtInKind = try container.decodeIfPresent(
            MobileTaskBuiltInTemplateKind.self,
            forKey: .builtInKind
        )
        let encodedIsBuiltIn = try container.decodeIfPresent(
            Bool.self,
            forKey: .isBuiltIn
        ) ?? false
        isBuiltIn = encodedIsBuiltIn || builtInKind != nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(defaultDirectory, forKey: .defaultDirectory)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encodeIfPresent(builtInKind, forKey: .builtInKind)
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
            MobileTaskTemplate(
                name: claudeName,
                icon: "agent:claude",
                command: "claude -- \"$CMUX_TASK_PROMPT\"",
                builtInKind: .claude
            ),
            MobileTaskTemplate(
                name: codexName,
                icon: "agent:codex",
                command: "codex -- \"$CMUX_TASK_PROMPT\"",
                builtInKind: .codex
            ),
            MobileTaskTemplate(
                name: openCodeName,
                icon: "agent:opencode",
                command: "opencode --prompt \"$CMUX_TASK_PROMPT\"",
                builtInKind: .openCode
            ),
            MobileTaskTemplate(
                name: shellName,
                icon: "terminal",
                command: "",
                builtInKind: .shell
            ),
        ]
    }
}
