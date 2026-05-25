enum TerminalDirectoryOpenShortcutBindings {
    typealias Binding = (target: TerminalDirectoryOpenTarget, action: KeyboardShortcutSettings.Action)

    static let all: [Binding] = TerminalDirectoryOpenTarget.commandPaletteShortcutTargets.map { target in
        (target, KeyboardShortcutSettings.Action.terminalDirectoryOpenAction(for: target))
    }

    static let actions: [KeyboardShortcutSettings.Action] = all.map { $0.action }
}

extension KeyboardShortcutSettings.Action {
    static var terminalDirectoryOpenActions: [Self] {
        TerminalDirectoryOpenShortcutBindings.actions
    }

    static var terminalDirectoryOpenShortcutBindings: [TerminalDirectoryOpenShortcutBindings.Binding] {
        TerminalDirectoryOpenShortcutBindings.all
    }

    static func terminalDirectoryOpenAction(for target: TerminalDirectoryOpenTarget) -> Self {
        switch target {
        case .androidStudio:
            return .terminalOpenDirectoryAndroidStudio
        case .antigravity:
            return .terminalOpenDirectoryAntigravity
        case .cursor:
            return .terminalOpenDirectoryCursor
        case .finder:
            return .terminalOpenDirectoryFinder
        case .ghostty:
            return .terminalOpenDirectoryGhostty
        case .intellij:
            return .terminalOpenDirectoryIntelliJ
        case .iterm2:
            return .terminalOpenDirectoryITerm2
        case .terminal:
            return .terminalOpenDirectoryTerminal
        case .tower:
            return .terminalOpenDirectoryTower
        case .vscode:
            return .terminalOpenDirectoryVSCode
        case .vscodeInline:
            return .terminalOpenDirectoryVSCodeInline
        case .warp:
            return .terminalOpenDirectoryWarp
        case .windsurf:
            return .terminalOpenDirectoryWindsurf
        case .xcode:
            return .terminalOpenDirectoryXcode
        case .zed:
            return .terminalOpenDirectoryZed
        }
    }

    var terminalDirectoryOpenTarget: TerminalDirectoryOpenTarget? {
        TerminalDirectoryOpenShortcutBindings.all.first { $0.action == self }?.target
    }
}
