import Foundation

extension TerminalTextBoxInputSettings {
    static func submitActions(defaults: UserDefaults = .standard) -> [TextBoxSubmitAction] {
        if let data = defaults.data(forKey: submitActionsKey),
           let decoded = try? JSONDecoder().decode([TextBoxSubmitAction].self, from: data) {
            return TextBoxSubmitAction.normalizedCatalog(decoded)
        }
        return submitActions(configuredJSON: defaults.string(forKey: submitActionsKey))
    }

    static func submitActions(configuredJSON raw: String?) -> [TextBoxSubmitAction] {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([TextBoxSubmitAction].self, from: data) else {
            return TextBoxSubmitAction.builtInActions
        }
        return TextBoxSubmitAction.normalizedCatalog(decoded)
    }

    static func defaultSubmitActionIDValue(defaults: UserDefaults = .standard) -> String {
        let configured = defaults.string(forKey: defaultSubmitActionKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = submitActions(defaults: defaults)
        if configured == TextBoxSubmitAction.textEntryAction.id {
            return TextBoxSubmitAction.textEntryAction.id
        }
        guard let configured,
              !configured.isEmpty else {
            return defaultSubmitActionID
        }
        guard actions.contains(where: { $0.id == configured }) else {
            return TextBoxSubmitAction.builtInActions.contains(where: { $0.id == configured })
                ? defaultSubmitActionID
                : TextBoxSubmitAction.textEntryAction.id
        }
        return configured
    }
}

struct TextBoxSubmitAction: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case textEntry
        case commandTemplate
    }

    let id: String
    let title: String
    let kind: Kind
    let commandTemplate: String?
    let preservePromptAfterLaunch: Bool?
    let systemImage: String
    let assetName: String?
    let imagePath: String?
    let backgroundColorHex: String

    init(
        id: String,
        title: String,
        kind: Kind,
        commandTemplate: String? = nil,
        preservePromptAfterLaunch: Bool? = nil,
        systemImage: String,
        assetName: String? = nil,
        imagePath: String? = nil,
        backgroundColorHex: String
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.commandTemplate = commandTemplate
        self.preservePromptAfterLaunch = preservePromptAfterLaunch
        self.systemImage = systemImage
        self.assetName = assetName
        self.imagePath = imagePath
        self.backgroundColorHex = backgroundColorHex
    }

    static let textEntryAction = TextBoxSubmitAction(
        id: "text-entry",
        title: "Text Entry",
        kind: .textEntry,
        systemImage: "arrow.up",
        backgroundColorHex: "#FFFFFF"
    )

    static let builtInActions: [TextBoxSubmitAction] = [
        TextBoxSubmitAction(
            id: "claude",
            title: "Claude",
            kind: .commandTemplate,
            commandTemplate: "claude",
            preservePromptAfterLaunch: true,
            systemImage: "sparkle",
            assetName: "AgentIcons/Claude",
            backgroundColorHex: "#F6D5C8"
        ),
        TextBoxSubmitAction(
            id: "codex",
            title: "Codex",
            kind: .commandTemplate,
            commandTemplate: "codex",
            preservePromptAfterLaunch: true,
            systemImage: "sparkles",
            assetName: "AgentIcons/Codex",
            backgroundColorHex: "#8FDBFF"
        ),
        TextBoxSubmitAction(
            id: "opencode",
            title: "OpenCode",
            kind: .commandTemplate,
            commandTemplate: "opencode",
            preservePromptAfterLaunch: true,
            systemImage: "curlybraces",
            assetName: "AgentIcons/OpenCode",
            backgroundColorHex: "#B5E48C"
        ),
        TextBoxSubmitAction(
            id: "pi",
            title: "Pi",
            kind: .commandTemplate,
            commandTemplate: "pi",
            preservePromptAfterLaunch: true,
            systemImage: "brain.head.profile",
            assetName: "AgentIcons/Pi",
            backgroundColorHex: "#D0B3FF"
        ),
    ]

    static func normalizedCatalog(_ configuredActions: [TextBoxSubmitAction]) -> [TextBoxSubmitAction] {
        var actionsByID: [String: TextBoxSubmitAction] = [:]
        var orderedIDs: [String] = []

        func append(_ action: TextBoxSubmitAction) {
            guard action.isValid else { return }
            if actionsByID[action.id] == nil {
                orderedIDs.append(action.id)
            }
            actionsByID[action.id] = action
        }

        builtInActions.forEach(append)
        configuredActions.forEach(append)

        return orderedIDs.compactMap { actionsByID[$0] }
    }

    var isValid: Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch kind {
        case .textEntry:
            return true
        case .commandTemplate:
            guard let commandTemplate,
                  !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return commandTemplate.contains("{{prompt}}") || shouldPreservePromptAfterLaunch
        }
    }

    var shouldPreservePromptAfterLaunch: Bool {
        preservePromptAfterLaunch == true
    }

    func launchCommand() -> String? {
        guard kind == .commandTemplate,
              shouldPreservePromptAfterLaunch,
              let commandTemplate,
              !commandTemplate.contains("{{prompt}}") else {
            return nil
        }
        let command = commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    func command(forPrompt prompt: String) -> String? {
        guard kind == .commandTemplate,
              let commandTemplate,
              commandTemplate.contains("{{prompt}}") else {
            return nil
        }
        return commandTemplate.replacingOccurrences(
            of: "{{prompt}}",
            with: Self.shellQuoted(prompt)
        )
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
