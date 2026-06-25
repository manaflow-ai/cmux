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
        TextBoxSubmitAction(
            id: "claude",
            title: "Claude Dangerous",
            kind: .commandTemplate,
            commandTemplate: "claude --dangerously-skip-permissions {{prompt}}",
            systemImage: "sparkle",
            assetName: "AgentIcons/Claude",
            backgroundColorHex: "#F6D5C8"
        ),
        TextBoxSubmitAction(
            id: "codex",
            title: "Codex Yolo",
            kind: .commandTemplate,
            commandTemplate: "codex --dangerously-bypass-approvals-and-sandbox",
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

    var pendingTerminalAgentContext: String? {
        launchCommand().map { "initialCommand:\($0)" }
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
