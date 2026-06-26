import Foundation

struct TextBoxSubmitAction: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: TextBoxSubmitActionKind
    let commandTemplate: String?
    let preservePromptAfterLaunch: Bool?
    let systemImage: String
    let assetName: String?
    let imagePath: String?
    let backgroundColorHex: String

    init(
        id: String,
        title: String,
        kind: TextBoxSubmitActionKind,
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
        builtInAgentAction(
            id: "claude",
            title: "Claude Dangerous",
            commandPrefix: "claude --dangerously-skip-permissions",
            systemImage: "sparkle",
            assetName: "AgentIcons/Claude",
            backgroundColorHex: "#F6D5C8"
        ),
        builtInAgentAction(
            id: "codex",
            title: "Codex Yolo",
            commandPrefix: "codex --dangerously-bypass-approvals-and-sandbox",
            systemImage: "sparkles",
            assetName: "AgentIcons/Codex",
            backgroundColorHex: "#8FDBFF"
        ),
        builtInAgentAction(
            id: "opencode",
            title: "OpenCode",
            commandPrefix: "opencode --prompt",
            systemImage: "curlybraces",
            assetName: "AgentIcons/OpenCode",
            backgroundColorHex: "#B5E48C"
        ),
        builtInAgentAction(
            id: "pi",
            title: "Pi",
            commandPrefix: "pi",
            systemImage: "brain.head.profile",
            assetName: "AgentIcons/Pi",
            backgroundColorHex: "#D0B3FF"
        ),
    ]

    private static func builtInAgentAction(
        id: String,
        title: String,
        commandPrefix: String,
        systemImage: String,
        assetName: String,
        backgroundColorHex: String
    ) -> TextBoxSubmitAction {
        TextBoxSubmitAction(
            id: id,
            title: title,
            kind: .commandTemplate,
            commandTemplate: "\(commandPrefix) {{prompt}}",
            systemImage: systemImage,
            assetName: assetName,
            backgroundColorHex: backgroundColorHex
        )
    }

    static let selectableActions: [TextBoxSubmitAction] = [textEntryAction] + builtInActions

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

        selectableActions.forEach(append)
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
            if commandTemplate.contains(Self.promptPlaceholder) {
                return Self.promptPlaceholdersAreUnquoted(in: commandTemplate)
            }
            return shouldPreservePromptAfterLaunch
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

    var pendingTerminalAgentContext: String? {
        launchCommand().map { "initialCommand:\($0)" }
    }

    func launchContextCommand() -> String? {
        if let launchCommand = launchCommand() {
            return launchCommand
        }
        guard kind == .commandTemplate,
              let commandTemplate,
              commandTemplate.contains(Self.promptPlaceholder),
              Self.promptPlaceholdersAreUnquoted(in: commandTemplate) else {
            return nil
        }
        let command = commandTemplate.replacingOccurrences(
            of: Self.promptPlaceholder,
            with: ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    func command(forPrompt prompt: String) -> String? {
        guard kind == .commandTemplate,
              let commandTemplate,
              commandTemplate.contains(Self.promptPlaceholder),
              Self.promptPlaceholdersAreUnquoted(in: commandTemplate) else {
            return nil
        }
        return commandTemplate.replacingOccurrences(
            of: Self.promptPlaceholder,
            with: Self.shellQuoted(prompt)
        )
    }

    private static let promptPlaceholder = "{{prompt}}"

    private static func promptPlaceholdersAreUnquoted(in template: String) -> Bool {
        var foundPlaceholder = false
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false
        var index = template.startIndex

        while index < template.endIndex {
            if template[index...].hasPrefix(promptPlaceholder) {
                foundPlaceholder = true
                guard !inSingleQuote, !inDoubleQuote else { return false }
                index = template.index(index, offsetBy: promptPlaceholder.count)
                escaping = false
                continue
            }

            let character = template[index]
            if escaping {
                escaping = false
                index = template.index(after: index)
                continue
            }

            if character == "\\" && !inSingleQuote {
                escaping = true
            } else if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            }
            index = template.index(after: index)
        }

        return foundPlaceholder
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
