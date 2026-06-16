import AppKit
import Combine
import Foundation

struct TerminalCommandHistoryItem: Identifiable, Equatable {
    let id: UUID
    let command: String
    let cwd: String?
    let shell: String?
    let startedAt: Date
    let panelId: UUID

    init(
        id: UUID = UUID(),
        command: String,
        cwd: String? = nil,
        shell: String? = nil,
        startedAt: Date = Date(),
        panelId: UUID
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.shell = shell
        self.startedAt = startedAt
        self.panelId = panelId
    }
}

struct TerminalCommandHistorySnapshotEntry: Equatable {
    let command: String
    let startedAt: Date?

    init(command: String, startedAt: Date? = nil) {
        self.command = command
        self.startedAt = startedAt
    }
}

enum TerminalCommandHistoryKeyEvent: Equatable {
    case up
    case down
    case right
    case escape
    case enter
}

struct TerminalCommandHistoryAcceptedCommand: Equatable {
    let command: String
    let replacementPrefix: String

    var needsInputReplacement: Bool {
        true
    }
}

enum TerminalCommandHistoryKeyHandlingResult: Equatable {
    case passThrough
    case consume
    case accept(TerminalCommandHistoryAcceptedCommand)
    case insertForEdit(TerminalCommandHistoryAcceptedCommand)
}

struct TerminalCommandHistoryMenuState: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let promptPrefix: String
    var items: [TerminalCommandHistoryItem]
    var selectedIndex: Int

    var selectedItem: TerminalCommandHistoryItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func matches(workspaceId: UUID, panelId: UUID) -> Bool {
        self.workspaceId == workspaceId && self.panelId == panelId
    }
}

@MainActor
final class TerminalCommandHistoryStore: ObservableObject {
    static let shared = TerminalCommandHistoryStore()

    private struct Scope: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    @Published private(set) var activeMenu: TerminalCommandHistoryMenuState?

    private let maxEntriesPerPanel: Int
    private var historyByScope: [Scope: [TerminalCommandHistoryItem]] = [:]
    private var promptInputsByScope: [Scope: PromptInputState] = [:]
    private var menuAutoOpenSuppressedScopes: Set<Scope> = []

    private enum PromptInputState: Equatable {
        case reliable(String)
        case unreliable
    }

    init(maxEntriesPerPanel: Int = 500) {
        self.maxEntriesPerPanel = max(1, maxEntriesPerPanel)
    }

    @discardableResult
    func record(
        workspaceId: UUID,
        panelId: UUID,
        command: String,
        cwd: String? = nil,
        shell: String? = nil,
        startedAt: Date = Date()
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        var entries = historyByScope[scope] ?? []
        if entries.last?.command == trimmed {
            return false
        }

        entries.append(
            TerminalCommandHistoryItem(
                command: trimmed,
                cwd: normalizedOptional(cwd),
                shell: normalizedOptional(shell),
                startedAt: startedAt,
                panelId: panelId
            )
        )
        if entries.count > maxEntriesPerPanel {
            entries.removeFirst(entries.count - maxEntriesPerPanel)
        }
        historyByScope[scope] = entries
        return true
    }

    func replaceShellHistorySnapshot(
        workspaceId: UUID,
        panelId: UUID,
        commands: [String],
        shell: String? = nil,
        capturedAt: Date = Date()
    ) {
        replaceShellHistorySnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            entries: commands.map { TerminalCommandHistorySnapshotEntry(command: $0) },
            shell: shell,
            capturedAt: capturedAt
        )
    }

    func replaceShellHistorySnapshot(
        workspaceId: UUID,
        panelId: UUID,
        entries snapshotEntries: [TerminalCommandHistorySnapshotEntry],
        shell: String? = nil,
        capturedAt: Date = Date()
    ) {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        var previousLatestByCommand: [String: TerminalCommandHistoryItem] = [:]
        for item in historyByScope[scope] ?? [] {
            if let existing = previousLatestByCommand[item.command],
               existing.startedAt >= item.startedAt {
                continue
            }
            previousLatestByCommand[item.command] = item
        }

        var entries: [TerminalCommandHistoryItem] = []
        entries.reserveCapacity(min(snapshotEntries.count, maxEntriesPerPanel))
        for snapshotEntry in snapshotEntries {
            let trimmed = snapshotEntry.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let startedAt = snapshotEntry.startedAt
                ?? previousLatestByCommand[trimmed]?.startedAt
                ?? capturedAt
            entries.append(
                TerminalCommandHistoryItem(
                    command: trimmed,
                    cwd: nil,
                    shell: normalizedOptional(shell),
                    startedAt: startedAt,
                    panelId: panelId
                )
            )
        }
        if entries.count > maxEntriesPerPanel {
            entries.removeFirst(entries.count - maxEntriesPerPanel)
        }
        historyByScope[scope] = entries
        refreshActiveMenuIfNeeded(workspaceId: workspaceId, panelId: panelId)
    }

    func recentCommands(workspaceId: UUID, panelId: UUID, limit: Int = 100) -> [TerminalCommandHistoryItem] {
        recentCommands(workspaceId: workspaceId, panelId: panelId, matchingPrefix: "", limit: limit)
    }

    func recentCommands(
        workspaceId: UUID,
        panelId: UUID,
        matchingPrefix prefix: String,
        limit: Int = 100
    ) -> [TerminalCommandHistoryItem] {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        let entries = historyByScope[scope] ?? []
        let trimmedPrefix = prefix.trimmingCharacters(in: .newlines)
        var seenCommands: Set<String> = []
        var filtered: [TerminalCommandHistoryItem] = []
        filtered.reserveCapacity(min(entries.count, max(0, limit)))
        for item in entries.reversed() {
            guard trimmedPrefix.isEmpty || item.command.hasPrefix(trimmedPrefix) else { continue }
            guard seenCommands.insert(item.command).inserted else { continue }
            filtered.append(item)
            if filtered.count >= max(0, limit) { break }
        }
        return filtered
    }

    func markPromptIdle(workspaceId: UUID, panelId: UUID) {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        promptInputsByScope[scope] = .reliable("")
        menuAutoOpenSuppressedScopes.remove(scope)
    }

    func markCommandRunning(workspaceId: UUID, panelId: UUID) {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        promptInputsByScope.removeValue(forKey: scope)
        menuAutoOpenSuppressedScopes.remove(scope)
        if activeMenu?.matches(workspaceId: workspaceId, panelId: panelId) == true {
            activeMenu = nil
        }
    }

    func markPromptInputDirty(workspaceId: UUID, panelId: UUID) {
        markPromptInputUnreliable(workspaceId: workspaceId, panelId: panelId)
    }

    func markPromptInputUnreliable(workspaceId: UUID, panelId: UUID) {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        promptInputsByScope[scope] = .unreliable
        menuAutoOpenSuppressedScopes.remove(scope)
        if activeMenu?.matches(workspaceId: workspaceId, panelId: panelId) == true {
            activeMenu = nil
        }
    }

    func appendPromptInputText(_ text: String, workspaceId: UUID, panelId: UUID) {
        guard !text.isEmpty else { return }
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        guard case .reliable(let current) = promptInputsByScope[scope] else { return }
        let next = current + text
        promptInputsByScope[scope] = .reliable(next)
        guard !menuAutoOpenSuppressedScopes.contains(scope) else { return }
        openOrRefreshMenu(workspaceId: workspaceId, panelId: panelId, promptPrefix: next)
    }

    func previewPromptInputText(_ text: String, workspaceId: UUID, panelId: UUID) {
        guard !text.isEmpty else { return }
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        guard case .reliable(let current) = promptInputsByScope[scope] else { return }
        guard !menuAutoOpenSuppressedScopes.contains(scope) else { return }
        openOrRefreshMenu(workspaceId: workspaceId, panelId: panelId, promptPrefix: current + text)
    }

    func deletePromptInputBackward(workspaceId: UUID, panelId: UUID) {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        guard case .reliable(var current) = promptInputsByScope[scope] else { return }
        guard !current.isEmpty else { return }
        current.removeLast()
        promptInputsByScope[scope] = .reliable(current)
        if menuAutoOpenSuppressedScopes.contains(scope) {
            return
        }
        if activeMenu?.matches(workspaceId: workspaceId, panelId: panelId) == true {
            if current.isEmpty {
                activeMenu = nil
            } else {
                openOrRefreshMenu(workspaceId: workspaceId, panelId: panelId, promptPrefix: current)
            }
        }
    }

    func isPromptInputClean(workspaceId: UUID, panelId: UUID) -> Bool {
        currentPromptInput(workspaceId: workspaceId, panelId: panelId) == ""
    }

    func currentPromptInput(workspaceId: UUID, panelId: UUID) -> String? {
        let scope = Scope(workspaceId: workspaceId, panelId: panelId)
        guard case .reliable(let text) = promptInputsByScope[scope] else { return nil }
        return text
    }

    func closeMenu() {
        activeMenu = nil
    }

    func accept(item: TerminalCommandHistoryItem) -> TerminalCommandHistoryAcceptedCommand {
        let prefix = activeMenu?.promptPrefix ?? ""
        activeMenu = nil
        return TerminalCommandHistoryAcceptedCommand(
            command: item.command,
            replacementPrefix: prefix
        )
    }

    func removeAll() {
        historyByScope.removeAll()
        promptInputsByScope.removeAll()
        menuAutoOpenSuppressedScopes.removeAll()
        activeMenu = nil
    }

    func handleKey(
        _ key: TerminalCommandHistoryKeyEvent,
        workspaceId: UUID,
        panelId: UUID,
        shellState: Workspace.PanelShellActivityState,
        hasMarkedText: Bool,
        searchVisible: Bool,
        keyboardCopyModeActive: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> TerminalCommandHistoryKeyHandlingResult {
        if hasHistoryMenuModifiers(modifierFlags) {
            return .passThrough
        }

        if activeMenu?.matches(workspaceId: workspaceId, panelId: panelId) == true {
            return handleMenuKey(key, workspaceId: workspaceId, panelId: panelId)
        }

        guard key == .up || key == .down else { return .passThrough }
        guard shellState == .promptIdle,
              !hasMarkedText,
              !searchVisible,
              !keyboardCopyModeActive
        else {
            return .passThrough
        }
        let promptPrefix = currentPromptInput(workspaceId: workspaceId, panelId: panelId) ?? ""

        let items = recentCommands(
            workspaceId: workspaceId,
            panelId: panelId,
            matchingPrefix: promptPrefix,
            limit: 50
        )
        menuAutoOpenSuppressedScopes.remove(Scope(workspaceId: workspaceId, panelId: panelId))
        openMenu(workspaceId: workspaceId, panelId: panelId, promptPrefix: promptPrefix, items: items)
        return .consume
    }

    private func handleMenuKey(
        _ key: TerminalCommandHistoryKeyEvent,
        workspaceId: UUID,
        panelId: UUID
    ) -> TerminalCommandHistoryKeyHandlingResult {
        guard var menu = activeMenu else { return .passThrough }
        switch key {
        case .up:
            menu.selectedIndex = max(0, menu.selectedIndex - 1)
            activeMenu = menu
            return .consume
        case .down:
            menu.selectedIndex = min(max(0, menu.items.count - 1), menu.selectedIndex + 1)
            activeMenu = menu
            return .consume
        case .right:
            guard let command = menu.selectedItem?.command else {
                activeMenu = nil
                return .consume
            }
            let scope = Scope(workspaceId: workspaceId, panelId: panelId)
            activeMenu = nil
            promptInputsByScope[scope] = .reliable(command)
            menuAutoOpenSuppressedScopes.insert(scope)
            return .insertForEdit(
                TerminalCommandHistoryAcceptedCommand(
                    command: command,
                    replacementPrefix: menu.promptPrefix
                )
            )
        case .escape:
            activeMenu = nil
            return .consume
        case .enter:
            guard let command = menu.selectedItem?.command else {
                activeMenu = nil
                return .consume
            }
            activeMenu = nil
            return .accept(
                TerminalCommandHistoryAcceptedCommand(
                    command: command,
                    replacementPrefix: menu.promptPrefix
                )
            )
        }
    }

    private func hasHistoryMenuModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        let normalized = flags.subtracting([.numericPad, .function, .capsLock])
        let disallowed: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        return !normalized.intersection(disallowed).isEmpty
    }

    private func refreshActiveMenuIfNeeded(workspaceId: UUID, panelId: UUID) {
        guard let menu = activeMenu,
              menu.matches(workspaceId: workspaceId, panelId: panelId) else {
            return
        }
        openOrRefreshMenu(workspaceId: workspaceId, panelId: panelId, promptPrefix: menu.promptPrefix)
    }

    private func openOrRefreshMenu(workspaceId: UUID, panelId: UUID, promptPrefix: String) {
        let items = recentCommands(
            workspaceId: workspaceId,
            panelId: panelId,
            matchingPrefix: promptPrefix,
            limit: 50
        )
        openMenu(workspaceId: workspaceId, panelId: panelId, promptPrefix: promptPrefix, items: items)
    }

    private func openMenu(
        workspaceId: UUID,
        panelId: UUID,
        promptPrefix: String,
        items: [TerminalCommandHistoryItem]
    ) {
        let previousSelectedCommand = activeMenu?.matches(workspaceId: workspaceId, panelId: panelId) == true
            ? activeMenu?.selectedItem?.command
            : nil
        let selectedIndex: Int
        if let previousSelectedCommand,
           let index = items.firstIndex(where: { $0.command == previousSelectedCommand }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
        activeMenu = TerminalCommandHistoryMenuState(
            workspaceId: workspaceId,
            panelId: panelId,
            promptPrefix: promptPrefix,
            items: items,
            selectedIndex: selectedIndex
        )
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
