import Foundation

enum CommandPaletteMode {
    case commands
    case renameInput(CommandPaletteRenameTarget)
    case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
    case workspaceDescriptionInput(CommandPaletteWorkspaceDescriptionTarget)
}

enum CommandPaletteListScope: String {
    case commands
    case switcher
}

enum CommandPalettePendingActivation: Equatable {
    case selected(requestID: UInt64, fallbackSelectedIndex: Int, preferredCommandID: String?)
    case command(requestID: UInt64, commandID: String)
}

enum CommandPaletteResolvedActivation: Equatable {
    case selected(index: Int)
    case command(commandID: String)
}

struct CommandPaletteRenameTarget: Equatable {
    enum Kind: Equatable {
        case workspace(workspaceId: UUID)
        case tab(workspaceId: UUID, panelId: UUID)
    }

    let kind: Kind
    let currentName: String

    var title: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceTitle", defaultValue: "Rename Workspace")
        case .tab:
            return String(localized: "commandPalette.rename.tabTitle", defaultValue: "Rename Tab")
        }
    }

    var description: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceDescription", defaultValue: "Choose a custom workspace name.")
        case .tab:
            return String(localized: "commandPalette.rename.tabDescription", defaultValue: "Choose a custom tab name.")
        }
    }

    var placeholder: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspacePlaceholder", defaultValue: "Workspace name")
        case .tab:
            return String(localized: "commandPalette.rename.tabPlaceholder", defaultValue: "Tab name")
        }
    }
}

struct CommandPaletteWorkspaceDescriptionTarget: Equatable {
    let workspaceId: UUID
    let currentDescription: String

    var placeholder: String {
        String(
            localized: "commandPalette.description.workspacePlaceholder",
            defaultValue: "Workspace description"
        )
    }

    var inputHint: String {
        String(
            localized: "commandPalette.description.workspaceInputHint",
            defaultValue: "Press Enter to save. Press Shift-Enter for a new line, or Escape to cancel."
        )
    }
}

struct CommandPaletteRestoreFocusTarget {
    let workspaceId: UUID
    let panelId: UUID
    let intent: PanelFocusIntent
}

enum CommandPaletteInputFocusTarget {
    case search
    case rename
}

enum CommandPaletteTextSelectionBehavior {
    case caretAtEnd
    case selectAll
}

enum CommandPaletteTrailingLabelStyle {
    case shortcut
    case kind
}

struct CommandPaletteTrailingLabel {
    let text: String
    let style: CommandPaletteTrailingLabelStyle
}

struct CommandPaletteInputFocusPolicy {
    let focusTarget: CommandPaletteInputFocusTarget
    let selectionBehavior: CommandPaletteTextSelectionBehavior

    static let search = CommandPaletteInputFocusPolicy(
        focusTarget: .search,
        selectionBehavior: .caretAtEnd
    )
}

struct CommandPaletteCommand: Identifiable {
    let id: String
    let rank: Int
    let title: String
    let subtitle: String
    let shortcutHint: String?
    let kindLabel: String?
    let keywords: [String]
    let dismissOnRun: Bool
    let action: () -> Void

    var searchableTexts: [String] {
        [title, subtitle] + keywords
    }
}

struct CommandPaletteUsageEntry: Codable, Sendable {
    var useCount: Int
    var lastUsedAt: TimeInterval
}

struct CommandPaletteContextSnapshot {
    private var boolValues: [String: Bool] = [:]
    private var stringValues: [String: String] = [:]

    init() {}

    mutating func setBool(_ key: String, _ value: Bool) {
        boolValues[key] = value
    }

    mutating func setString(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else {
            stringValues.removeValue(forKey: key)
            return
        }
        stringValues[key] = value
    }

    func bool(_ key: String) -> Bool {
        boolValues[key] ?? false
    }

    func string(_ key: String) -> String? {
        stringValues[key]
    }

    func fingerprint() -> Int {
        ContentView.commandPaletteContextFingerprint(
            boolValues: boolValues,
            stringValues: stringValues
        )
    }
}

struct CommandPaletteCommandsContext {
    let snapshot: CommandPaletteContextSnapshot
}

enum CommandPaletteContextKeys {
    static let hasWorkspace = "workspace.hasSelection"
    static let workspaceName = "workspace.name"
    static let workspaceHasCustomName = "workspace.hasCustomName"
    static let workspaceHasCustomDescription = "workspace.hasCustomDescription"
    static let workspaceMinimalModeEnabled = "workspace.minimalModeEnabled"
    static let workspaceShouldPin = "workspace.shouldPin"
    static let workspaceHasPullRequests = "workspace.hasPullRequests"
    static let workspaceHasSplits = "workspace.hasSplits"
    static let workspaceHasPeers = "workspace.hasPeers"
    static let workspaceHasAbove = "workspace.hasAbove"
    static let workspaceHasBelow = "workspace.hasBelow"
    static let workspaceCanMarkRead = "workspace.canMarkRead"
    static let workspaceCanMarkUnread = "workspace.canMarkUnread"
    static let sidebarMatchTerminalBackground = "sidebar.matchTerminalBackground"
    static let hasFocusedPanel = "panel.hasFocus"
    static let panelName = "panel.name"
    static let panelIsBrowser = "panel.isBrowser"
    static let panelIsTerminal = "panel.isTerminal"
    static let panelHasPane = "panel.hasPane"
    static let panelHasCustomName = "panel.hasCustomName"
    static let panelShouldPin = "panel.shouldPin"
    static let panelHasUnread = "panel.hasUnread"
    static let panelCanMoveToNewWorkspace = "panel.canMoveToNewWorkspace"
    static let updateHasAvailable = "update.hasAvailable"
    static let cliInstalledInPATH = "cli.installedInPATH"
    static let browserDisabled = "browser.disabled"
    static let supportedFileRoutingDisabled = "filePreview.supportedFileRoutingDisabled"
    static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> String {
        "terminal.openTarget.\(target.rawValue).available"
    }
}

struct CommandPaletteCommandContribution {
    let commandId: String
    let title: (CommandPaletteContextSnapshot) -> String
    let subtitle: (CommandPaletteContextSnapshot) -> String
    let shortcutHint: String?
    let keywords: [String]
    let dismissOnRun: Bool
    let when: (CommandPaletteContextSnapshot) -> Bool
    let enablement: (CommandPaletteContextSnapshot) -> Bool

    init(
        commandId: String,
        title: @escaping (CommandPaletteContextSnapshot) -> String,
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        shortcutHint: String? = nil,
        keywords: [String] = [],
        dismissOnRun: Bool = true,
        when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
        enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.when = when
        self.enablement = enablement
    }
}

struct CommandPaletteHandlerRegistry {
    private var handlers: [String: () -> Void] = [:]

    mutating func register(commandId: String, handler: @escaping () -> Void) {
        guard handlers[commandId] == nil else {
            assertionFailure("Duplicate command palette handler id: \(commandId)")
            return
        }
        handlers[commandId] = handler
    }

    func handler(for commandId: String) -> (() -> Void)? {
        handlers[commandId]
    }
}

struct CommandPaletteSearchResult: Identifiable {
    let command: CommandPaletteCommand
    let score: Int
    let titleMatchIndices: Set<Int>

    var id: String { command.id }
}

struct CommandPaletteResolvedSearchMatch: Sendable {
    let commandID: String
    let score: Int
    let titleMatchIndices: Set<Int>
}

struct CommandPaletteSwitcherWindowContext {
    let windowId: UUID
    let tabManager: TabManager
    let selectedWorkspaceId: UUID?
    let windowLabel: String?
}

struct CommandPaletteSwitcherFingerprintWorkspace: Sendable {
    let id: UUID
    let displayName: String
    let metadata: CommandPaletteSwitcherSearchMetadata
    let surfaces: [CommandPaletteSwitcherFingerprintSurface]
}

struct CommandPaletteSwitcherFingerprintSurface: Sendable {
    let id: UUID
    let displayName: String
    let kindLabel: String
    let metadata: CommandPaletteSwitcherSearchMetadata
}

struct CommandPaletteSwitcherFingerprintContext: Sendable {
    let windowId: UUID
    let windowLabel: String?
    let selectedWorkspaceId: UUID?
    let workspaces: [CommandPaletteSwitcherFingerprintWorkspace]
}

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(String(localized: "taskManager.title", defaultValue: "Task Manager")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
        ]
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
    }
}
