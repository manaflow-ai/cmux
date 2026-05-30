import AppKit

private enum AppleScriptStrings {
    static let disabled = String(
        localized: "applescript.error.disabled",
        defaultValue: "AppleScript is disabled by the macos-applescript configuration."
    )
    static let missingAction = String(
        localized: "applescript.error.missingAction",
        defaultValue: "Missing action string."
    )
    static let missingInputText = String(
        localized: "applescript.error.missingInputText",
        defaultValue: "Missing input text."
    )
    static let missingTerminalTarget = String(
        localized: "applescript.error.missingTerminalTarget",
        defaultValue: "Missing terminal target."
    )
    static let missingSplitDirection = String(
        localized: "applescript.error.missingSplitDirection",
        defaultValue: "Missing or unknown split direction."
    )
    static let windowUnavailable = String(
        localized: "applescript.error.windowUnavailable",
        defaultValue: "Window is no longer available."
    )
    static let workspaceUnavailable = String(
        localized: "applescript.error.workspaceUnavailable",
        defaultValue: "Workspace is no longer available."
    )
    static let terminalUnavailable = String(
        localized: "applescript.error.terminalUnavailable",
        defaultValue: "Terminal is no longer available."
    )
    static let failedToCreateWindow = String(
        localized: "applescript.error.failedToCreateWindow",
        defaultValue: "Failed to create window."
    )
    static let failedToCreateWorkspace = String(
        localized: "applescript.error.failedToCreateWorkspace",
        defaultValue: "Failed to create workspace."
    )
    static let failedToCreateSplit = String(
        localized: "applescript.error.failedToCreateSplit",
        defaultValue: "Failed to create split."
    )
}

private extension String {
    var fourCharCode: UInt32 {
        utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }
}

private extension Workspace {
    func scriptingTerminalPanels() -> [TerminalPanel] {
        var results: [TerminalPanel] = []
        var seen: Set<UUID> = []

        for panelId in sidebarOrderedPanelIds() {
            guard seen.insert(panelId).inserted,
                  let terminal = terminalPanel(for: panelId) else {
                continue
            }
            results.append(terminal)
        }

        let remaining = panels.values
            .compactMap { $0 as? TerminalPanel }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        for terminal in remaining where seen.insert(terminal.id).inserted {
            results.append(terminal)
        }

        return results
    }
}

@MainActor
extension NSApplication {
    var isAppleScriptEnabled: Bool {
        // cmux always enables AppleScript — the underlying Ghostty fork
        // doesn't have the macos-applescript config key yet (added in
        // upstream ghostty commit 25fa58143, 2026-03-06), so
        // appleScriptAutomationEnabled() always returns false.
        // Once the fork is updated, this can revert to:
        //   GhosttyApp.shared.appleScriptAutomationEnabled()
        return true
    }

    @discardableResult
    func validateScript(command: NSScriptCommand) -> Bool {
        guard isAppleScriptEnabled else {
            command.scriptErrorNumber = errAEEventNotPermitted
            command.scriptErrorString = AppleScriptStrings.disabled
            return false
        }

        return true
    }

    @objc(scriptWindows)
    var scriptWindows: [ScriptWindow] {
        guard isAppleScriptEnabled,
              let appDelegate = AppDelegate.shared else {
            return []
        }
        return appDelegate.scriptableMainWindows().map { ScriptWindow(windowId: $0.windowId) }
    }

    @objc(frontWindow)
    var frontWindow: ScriptWindow? {
        scriptWindows.first
    }

    @objc(valueInScriptWindowsWithUniqueID:)
    func valueInScriptWindows(uniqueID: String) -> ScriptWindow? {
        guard isAppleScriptEnabled,
              let windowId = UUID(uuidString: uniqueID),
              let appDelegate = AppDelegate.shared,
              appDelegate.scriptableMainWindow(windowId: windowId) != nil else {
            return nil
        }
        return ScriptWindow(windowId: windowId)
    }

    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard isAppleScriptEnabled,
              let appDelegate = AppDelegate.shared else {
            return []
        }

        return appDelegate.scriptableMainWindows()
            .flatMap { state in
                state.tabManager.tabs.flatMap { workspace in
                    workspace.scriptingTerminalPanels().map {
                        ScriptTerminal(workspaceId: workspace.id, terminalId: $0.id)
                    }
                }
            }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard isAppleScriptEnabled,
              let terminalId = UUID(uuidString: uniqueID),
              let appDelegate = AppDelegate.shared else {
            return nil
        }

        for state in appDelegate.scriptableMainWindows() {
            for workspace in state.tabManager.tabs where workspace.terminalPanel(for: terminalId) != nil {
                return ScriptTerminal(workspaceId: workspace.id, terminalId: terminalId)
            }
        }

        return nil
    }

    @objc(handlePerformActionScriptCommand:)
    func handlePerformActionScriptCommand(_ command: NSScriptCommand) -> NSNumber? {
        guard validateScript(command: command) else { return nil }

        guard let action = command.directParameter as? String else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = AppleScriptStrings.missingAction
            return nil
        }

        guard let terminal = command.evaluatedArguments?["on"] as? ScriptTerminal else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = AppleScriptStrings.missingTerminalTarget
            return nil
        }

        return NSNumber(value: terminal.perform(action: action))
    }

    @objc(handleNewWindowScriptCommand:)
    func handleNewWindowScriptCommand(_ command: NSScriptCommand) -> ScriptWindow? {
        guard validateScript(command: command) else { return nil }

        guard let appDelegate = AppDelegate.shared else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.failedToCreateWindow
            return nil
        }

        let windowId = appDelegate.createMainWindow()
        return ScriptWindow(windowId: windowId)
    }

    @objc(handleNewTabScriptCommand:)
    func handleNewTabScriptCommand(_ command: NSScriptCommand) -> ScriptTab? {
        guard validateScript(command: command) else { return nil }

        guard let appDelegate = AppDelegate.shared else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.failedToCreateWorkspace
            return nil
        }

        if let targetWindow = command.evaluatedArguments?["window"] as? ScriptWindow {
            guard let workspaceId = appDelegate.addWorkspace(windowId: targetWindow.windowId, bringToFront: false) else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = AppleScriptStrings.failedToCreateWorkspace
                return nil
            }
            return ScriptTab(windowId: targetWindow.windowId, tabId: workspaceId)
        }

        if let frontWindow = scriptWindows.first,
           let workspaceId = appDelegate.addWorkspace(windowId: frontWindow.windowId, bringToFront: false) {
            return ScriptTab(windowId: frontWindow.windowId, tabId: workspaceId)
        }

        let windowId = appDelegate.createMainWindow()
        return ScriptWindow(windowId: windowId).selectedTab
    }

    @objc(handleQuitScriptCommand:)
    func handleQuitScriptCommand(_ command: NSScriptCommand) {
        guard validateScript(command: command) else { return }
        terminate(nil)
    }
}

@MainActor
@objc(CmuxScriptWindow)
final class ScriptWindow: NSObject {
    let windowId: UUID

    init(windowId: UUID) {
        self.windowId = windowId
    }

    private var state: AppDelegate.ScriptableMainWindowState? {
        AppDelegate.shared?.scriptableMainWindow(windowId: windowId)
    }

    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return windowId.uuidString
    }

    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled,
              let state else {
            return ""
        }

        let windowTitle = state.window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !windowTitle.isEmpty {
            return windowTitle
        }

        return state.tabManager.selectedWorkspace?.title ?? ""
    }

    @objc(tabs)
    var tabs: [ScriptTab] {
        guard NSApp.isAppleScriptEnabled,
              let state else {
            return []
        }
        return state.tabManager.tabs.map { ScriptTab(windowId: windowId, tabId: $0.id) }
    }

    @objc(selectedTab)
    var selectedTab: ScriptTab? {
        guard NSApp.isAppleScriptEnabled,
              let selectedId = state?.tabManager.selectedTabId else {
            return nil
        }
        return ScriptTab(windowId: windowId, tabId: selectedId)
    }

    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled,
              let state else {
            return []
        }
        return state.tabManager.tabs.flatMap { workspace in
            workspace.scriptingTerminalPanels().map {
                ScriptTerminal(workspaceId: workspace.id, terminalId: $0.id)
            }
        }
    }

    @objc(valueInTabsWithUniqueID:)
    func valueInTabs(uniqueID: String) -> ScriptTab? {
        guard NSApp.isAppleScriptEnabled,
              let tabId = UUID(uuidString: uniqueID),
              let state,
              state.tabManager.tabs.contains(where: { $0.id == tabId }) else {
            return nil
        }
        return ScriptTab(windowId: windowId, tabId: tabId)
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled,
              let terminalId = UUID(uuidString: uniqueID),
              let state else {
            return nil
        }

        for workspace in state.tabManager.tabs where workspace.terminalPanel(for: terminalId) != nil {
            return ScriptTerminal(workspaceId: workspace.id, terminalId: terminalId)
        }

        return nil
    }

    @objc(handleActivateWindowCommand:)
    func handleActivateWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard AppDelegate.shared?.focusScriptableMainWindow(windowId: windowId, bringToFront: true) == true else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.windowUnavailable
            return nil
        }

        return nil
    }

    @objc(handleCloseWindowCommand:)
    func handleCloseWindow(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let window = state?.window else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.windowUnavailable
            return nil
        }

        window.performClose(nil)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled,
              let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "scriptWindows",
            uniqueID: windowId.uuidString
        )
    }
}

@MainActor
@objc(CmuxScriptTab)
final class ScriptTab: NSObject {
    let windowId: UUID
    let tabId: UUID

    init(windowId: UUID, tabId: UUID) {
        self.windowId = windowId
        self.tabId = tabId
    }

    private var state: AppDelegate.ScriptableMainWindowState? {
        AppDelegate.shared?.scriptableMainWindow(windowId: windowId)
    }

    private var workspace: Workspace? {
        state?.tabManager.tabs.first(where: { $0.id == tabId })
    }

    private var window: ScriptWindow {
        ScriptWindow(windowId: windowId)
    }

    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return tabId.uuidString
    }

    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return workspace?.title ?? ""
    }

    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled,
              let state,
              let idx = state.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return 0
        }
        return idx + 1
    }

    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        return state?.tabManager.selectedTabId == tabId
    }

    @objc(focusedTerminal)
    var focusedTerminal: ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled,
              let terminalId = workspace?.focusedTerminalPanel?.id else {
            return nil
        }
        return ScriptTerminal(workspaceId: tabId, terminalId: terminalId)
    }

    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled,
              let workspace else {
            return []
        }
        return workspace.scriptingTerminalPanels().map {
            ScriptTerminal(workspaceId: tabId, terminalId: $0.id)
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled,
              let workspace,
              let terminalId = UUID(uuidString: uniqueID),
              workspace.terminalPanel(for: terminalId) != nil else {
            return nil
        }
        return ScriptTerminal(workspaceId: tabId, terminalId: terminalId)
    }

    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let state,
              let workspace else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.workspaceUnavailable
            return nil
        }

        state.tabManager.selectWorkspace(workspace)
        return nil
    }

    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let state,
              let workspace else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.workspaceUnavailable
            return nil
        }

        if state.tabManager.tabs.count > 1 {
            state.tabManager.closeWorkspace(workspace)
            return nil
        }

        guard let window = state.window else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.windowUnavailable
            return nil
        }

        window.performClose(nil)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled,
              let windowClassDescription = window.classDescription as? NSScriptClassDescription,
              let windowSpecifier = window.objectSpecifier else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: tabId.uuidString
        )
    }
}

@MainActor
@objc(CmuxScriptTerminal)
final class ScriptTerminal: NSObject {
    let workspaceId: UUID
    let terminalId: UUID

    init(workspaceId: UUID, terminalId: UUID) {
        self.workspaceId = workspaceId
        self.terminalId = terminalId
    }

    private var state: AppDelegate.ScriptableMainWindowState? {
        AppDelegate.shared?.scriptableMainWindowForTab(workspaceId)
    }

    private var workspace: Workspace? {
        state?.tabManager.tabs.first(where: { $0.id == workspaceId })
    }

    private var terminal: TerminalPanel? {
        workspace?.terminalPanel(for: terminalId)
    }

    @objc(id)
    var stableID: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return terminalId.uuidString
    }

    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return terminal?.displayTitle ?? ""
    }

    @objc(workingDirectory)
    var workingDirectory: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        // TerminalPanel.directory is never updated (updateDirectory is never called).
        // Read from Workspace.panelDirectories instead, which is kept up to date
        // via updatePanelDirectory() from OSC 7 / shell integration.
        return workspace?.panelDirectories[terminalId] ?? terminal?.directory ?? ""
    }

    func input(text: String) -> Bool {
        guard NSApp.isAppleScriptEnabled,
              let terminal else {
            return false
        }
        terminal.sendText(text)
        return true
    }

    func perform(action: String) -> Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        return terminal?.performBindingAction(action) ?? false
    }

    @objc(handleSplitCommand:)
    func handleSplit(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let directionCode = command.evaluatedArguments?["direction"] as? UInt32,
              let direction = ScriptSplitDirection(code: directionCode)?.splitDirection else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = AppleScriptStrings.missingSplitDirection
            return nil
        }

        guard let state,
              let workspace,
              terminal != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }

        guard let newPanelId = state.tabManager.newSplit(tabId: workspaceId, surfaceId: terminalId, direction: direction),
              workspace.terminalPanel(for: newPanelId) != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.failedToCreateSplit
            return nil
        }

        return ScriptTerminal(workspaceId: workspaceId, terminalId: newPanelId)
    }

    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let state,
              let workspace,
              terminal != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }

        if let app = AppDelegate.shared {
            _ = app.focusScriptableMainWindow(windowId: state.windowId, bringToFront: true)
        }
        state.tabManager.selectWorkspace(workspace)
        workspace.focusPanel(terminalId)
        return nil
    }

    @objc(handleCloseCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let state,
              let workspace,
              terminal != nil else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }

        if workspace.panels.count == 1 {
            if state.tabManager.tabs.count > 1 {
                state.tabManager.closeWorkspace(workspace)
                return nil
            }

            guard let window = state.window else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = AppleScriptStrings.windowUnavailable
                return nil
            }

            window.performClose(nil)
            return nil
        }

        guard workspace.closePanel(terminalId, force: true) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspaceId, surfaceId: terminalId)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled,
              let appClassDescription = NSApplication.shared.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSUniqueIDSpecifier(
            containerClassDescription: appClassDescription,
            containerSpecifier: nil,
            key: "terminals",
            uniqueID: terminalId.uuidString
        )
    }
}

@MainActor
@objc(CmuxScriptInputTextCommand)
final class ScriptInputTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard NSApp.validateScript(command: self) else { return nil }

        guard let text = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = AppleScriptStrings.missingInputText
            return nil
        }

        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = AppleScriptStrings.missingTerminalTarget
            return nil
        }

        guard terminal.input(text: text) else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = AppleScriptStrings.terminalUnavailable
            return nil
        }
        return nil
    }
}

private enum ScriptSplitDirection {
    case right
    case left
    case down
    case up

    init?(code: UInt32) {
        switch code {
        case "GSrt".fourCharCode: self = .right
        case "GSlf".fourCharCode: self = .left
        case "GSdn".fourCharCode: self = .down
        case "GSup".fourCharCode: self = .up
        default: return nil
        }
    }

    var splitDirection: SplitDirection {
        switch self {
        case .right: return .right
        case .left: return .left
        case .down: return .down
        case .up: return .up
        }
    }
}
