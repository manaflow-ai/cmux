import AppKit
import Bonsplit
import Carbon
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
    static let actionUserInfoKey = "action"
    static let settingsFileDisplayPath = "~/.config/cmux/settings.json"
    static let keybindingsFileDisplayPath = "~/.config/cmux/keybindings.json"
    static var settingsFileStore: KeyboardShortcutSettingsFileStore = .shared {
        didSet {
            notifySettingsFileDidChange()
        }
    }
    static var customCommandStore: CustomCommandStore = .shared

    enum Action: String, CaseIterable, Identifiable {
        // App / window
        case openSettings
        case reloadConfiguration
        case showHideAllWindows
        case newWindow
        case closeWindow
        case toggleFullScreen
        case quit

        // Titlebar / primary UI
        case toggleSidebar
        case newTab
        case openFolder
        case goToWorkspace
        case commandPalette
        case sendFeedback
        case showNotifications
        case jumpToUnread
        case triggerFlash

        // Navigation
        case nextSurface
        case prevSurface
        case selectSurfaceByNumber
        case nextSidebarTab
        case prevSidebarTab
        case selectWorkspaceByNumber
        case renameTab
        case renameWorkspace
        case editWorkspaceDescription
        case closeTab
        case closeOtherTabsInPane
        case closeWorkspace
        case reopenClosedBrowserPanel
        case newSurface
        case toggleTerminalCopyMode

        // Panes / splits
        case focusLeft
        case focusRight
        case focusUp
        case focusDown
        case splitRight
        case splitDown
        case toggleSplitZoom
        case splitBrowserRight
        case splitBrowserDown

        // File Explorer
        case toggleFileExplorer

        // Panels
        case openBrowser
        case focusBrowserAddressBar
        case browserBack
        case browserForward
        case browserReload
        case browserZoomIn
        case browserZoomOut
        case browserZoomReset
        case find
        case findNext
        case findPrevious
        case hideFind
        case useSelectionForFind
        case toggleBrowserDeveloperTools
        case showBrowserJavaScriptConsole
        case toggleReactGrab

        var id: String { rawValue }

        var label: String {
            switch self {
            case .openSettings: return String(localized: "menu.app.settings", defaultValue: "Settings…")
            case .reloadConfiguration: return String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration")
            case .showHideAllWindows: return String(localized: "settings.globalHotkey.shortcut", defaultValue: "Show/Hide All Windows")
            case .newWindow: return String(localized: "shortcut.newWindow.label", defaultValue: "New Window")
            case .closeWindow: return String(localized: "shortcut.closeWindow.label", defaultValue: "Close Window")
            case .toggleFullScreen: return String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")
            case .quit: return String(localized: "menu.quitCmux", defaultValue: "Quit cmux")
            case .toggleSidebar: return String(localized: "shortcut.toggleSidebar.label", defaultValue: "Toggle Sidebar")
            case .newTab: return String(localized: "shortcut.newWorkspace.label", defaultValue: "New Workspace")
            case .openFolder: return String(localized: "shortcut.openFolder.label", defaultValue: "Open Folder")
            case .goToWorkspace: return String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…")
            case .commandPalette: return String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…")
            case .sendFeedback: return String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback")
            case .showNotifications: return String(localized: "shortcut.showNotifications.label", defaultValue: "Show Notifications")
            case .jumpToUnread: return String(localized: "shortcut.jumpToUnread.label", defaultValue: "Jump to Latest Unread")
            case .triggerFlash: return String(localized: "shortcut.flashFocusedPanel.label", defaultValue: "Flash Focused Panel")
            case .nextSurface: return String(localized: "shortcut.nextSurface.label", defaultValue: "Next Surface")
            case .prevSurface: return String(localized: "shortcut.previousSurface.label", defaultValue: "Previous Surface")
            case .selectSurfaceByNumber: return String(localized: "shortcut.selectSurfaceByNumber.label", defaultValue: "Select Surface 1…9")
            case .nextSidebarTab: return String(localized: "shortcut.nextWorkspace.label", defaultValue: "Next Workspace")
            case .prevSidebarTab: return String(localized: "shortcut.previousWorkspace.label", defaultValue: "Previous Workspace")
            case .selectWorkspaceByNumber: return String(localized: "shortcut.selectWorkspaceByNumber.label", defaultValue: "Select Workspace 1…9")
            case .renameTab: return String(localized: "shortcut.renameTab.label", defaultValue: "Rename Tab")
            case .renameWorkspace: return String(localized: "shortcut.renameWorkspace.label", defaultValue: "Rename Workspace")
            case .editWorkspaceDescription: return String(localized: "shortcut.editWorkspaceDescription.label", defaultValue: "Edit Workspace Description")
            case .closeTab: return String(localized: "menu.file.closeTab", defaultValue: "Close Tab")
            case .closeOtherTabsInPane: return String(localized: "menu.file.closeOtherTabs", defaultValue: "Close Other Tabs in Pane")
            case .closeWorkspace: return String(localized: "shortcut.closeWorkspace.label", defaultValue: "Close Workspace")
            case .reopenClosedBrowserPanel: return String(localized: "menu.file.reopenClosedBrowserPanel", defaultValue: "Reopen Closed Browser Panel")
            case .newSurface: return String(localized: "shortcut.newSurface.label", defaultValue: "New Surface")
            case .toggleTerminalCopyMode: return String(localized: "shortcut.toggleTerminalCopyMode.label", defaultValue: "Toggle Terminal Copy Mode")
            case .focusLeft: return String(localized: "shortcut.focusPaneLeft.label", defaultValue: "Focus Pane Left")
            case .focusRight: return String(localized: "shortcut.focusPaneRight.label", defaultValue: "Focus Pane Right")
            case .focusUp: return String(localized: "shortcut.focusPaneUp.label", defaultValue: "Focus Pane Up")
            case .focusDown: return String(localized: "shortcut.focusPaneDown.label", defaultValue: "Focus Pane Down")
            case .splitRight: return String(localized: "shortcut.splitRight.label", defaultValue: "Split Right")
            case .splitDown: return String(localized: "shortcut.splitDown.label", defaultValue: "Split Down")
            case .toggleSplitZoom: return String(localized: "shortcut.togglePaneZoom.label", defaultValue: "Toggle Pane Zoom")
            case .splitBrowserRight: return String(localized: "shortcut.splitBrowserRight.label", defaultValue: "Split Browser Right")
            case .splitBrowserDown: return String(localized: "shortcut.splitBrowserDown.label", defaultValue: "Split Browser Down")
            case .toggleFileExplorer: return String(localized: "shortcut.toggleFileExplorer.label", defaultValue: "Toggle File Explorer")
            case .openBrowser: return String(localized: "shortcut.openBrowser.label", defaultValue: "Open Browser")
            case .focusBrowserAddressBar: return String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")
            case .browserBack: return String(localized: "menu.view.back", defaultValue: "Back")
            case .browserForward: return String(localized: "menu.view.forward", defaultValue: "Forward")
            case .browserReload: return String(localized: "menu.view.reloadPage", defaultValue: "Reload Page")
            case .browserZoomIn: return String(localized: "menu.view.zoomIn", defaultValue: "Zoom In")
            case .browserZoomOut: return String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out")
            case .browserZoomReset: return String(localized: "menu.view.actualSize", defaultValue: "Actual Size")
            case .find: return String(localized: "menu.find.find", defaultValue: "Find…")
            case .findNext: return String(localized: "menu.find.findNext", defaultValue: "Find Next")
            case .findPrevious: return String(localized: "menu.find.findPrevious", defaultValue: "Find Previous")
            case .hideFind: return String(localized: "menu.find.hideFindBar", defaultValue: "Hide Find Bar")
            case .useSelectionForFind: return String(localized: "menu.find.useSelectionForFind", defaultValue: "Use Selection for Find")
            case .toggleBrowserDeveloperTools: return String(localized: "shortcut.toggleBrowserDevTools.label", defaultValue: "Toggle Browser Developer Tools")
            case .showBrowserJavaScriptConsole: return String(localized: "shortcut.showBrowserJSConsole.label", defaultValue: "Show Browser JavaScript Console")
            case .toggleReactGrab: return String(localized: "shortcut.toggleReactGrab.label", defaultValue: "Toggle React Grab")
            }
        }

        var defaultsKey: String { "shortcut.\(rawValue)" }

        var defaultShortcut: StoredShortcut {
            switch self {
            case .openSettings:
                return StoredShortcut(key: ",", command: true, shift: false, option: false, control: false)
            case .reloadConfiguration:
                return StoredShortcut(key: ",", command: true, shift: true, option: false, control: false)
            case .showHideAllWindows:
                // Avoid AppKit-reserved keystrokes such as Cmd+. (modal
                // cancel). Default to Ctrl+Option+Cmd+. so the global hotkey
                // does not collide with the standard cancel keystroke that
                // NSAlert/NSOpenPanel use.
                return StoredShortcut(key: ".", command: true, shift: false, option: true, control: true)
            case .newWindow:
                return StoredShortcut(key: "n", command: true, shift: true, option: false, control: false)
            case .closeWindow:
                return StoredShortcut(key: "w", command: true, shift: false, option: false, control: true)
            case .toggleFullScreen:
                return StoredShortcut(key: "f", command: true, shift: false, option: false, control: true)
            case .quit:
                return StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)
            case .toggleSidebar:
                return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
            case .newTab:
                return StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
            case .openFolder:
                return StoredShortcut(key: "o", command: true, shift: false, option: false, control: false)
            case .goToWorkspace:
                return StoredShortcut(key: "p", command: true, shift: false, option: false, control: false)
            case .commandPalette:
                return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false)
            case .sendFeedback:
                return StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
            case .showNotifications:
                return StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
            case .jumpToUnread:
                return StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
            case .triggerFlash:
                return StoredShortcut(key: "h", command: true, shift: true, option: false, control: false)
            case .nextSidebarTab:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)
            case .prevSidebarTab:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: true)
            case .renameTab:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            case .renameWorkspace:
                return StoredShortcut(key: "r", command: true, shift: true, option: false, control: false)
            case .editWorkspaceDescription:
                return StoredShortcut(key: "e", command: true, shift: true, option: false, control: false)
            case .closeTab:
                return StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)
            case .closeOtherTabsInPane:
                return StoredShortcut(key: "t", command: true, shift: false, option: true, control: false)
            case .closeWorkspace:
                return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
            case .reopenClosedBrowserPanel:
                return StoredShortcut(key: "t", command: true, shift: true, option: false, control: false)
            case .focusLeft:
                return StoredShortcut(key: "←", command: true, shift: false, option: true, control: false)
            case .focusRight:
                return StoredShortcut(key: "→", command: true, shift: false, option: true, control: false)
            case .focusUp:
                return StoredShortcut(key: "↑", command: true, shift: false, option: true, control: false)
            case .focusDown:
                return StoredShortcut(key: "↓", command: true, shift: false, option: true, control: false)
            case .splitRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            case .splitDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
            case .toggleSplitZoom:
                return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
            case .splitBrowserRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: true, control: false)
            case .splitBrowserDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: true, control: false)
            case .nextSurface:
                return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
            case .prevSurface:
                return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
            case .selectSurfaceByNumber:
                return StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
            case .newSurface:
                return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            case .toggleTerminalCopyMode:
                return StoredShortcut(key: "m", command: true, shift: true, option: false, control: false)
            case .selectWorkspaceByNumber:
                return StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
            case .toggleFileExplorer:
                return StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
            case .openBrowser:
                return StoredShortcut(key: "l", command: true, shift: true, option: false, control: false)
            case .focusBrowserAddressBar:
                return StoredShortcut(key: "l", command: true, shift: false, option: false, control: false)
            case .browserBack:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: false)
            case .browserForward:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: false)
            case .browserReload:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            case .browserZoomIn:
                return StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
            case .browserZoomOut:
                return StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
            case .browserZoomReset:
                return StoredShortcut(key: "0", command: true, shift: false, option: false, control: false)
            case .find:
                return StoredShortcut(key: "f", command: true, shift: false, option: false, control: false)
            case .findNext:
                return StoredShortcut(key: "g", command: true, shift: false, option: false, control: false)
            case .findPrevious:
                return StoredShortcut(key: "g", command: true, shift: false, option: true, control: false)
            case .hideFind:
                return StoredShortcut(key: "f", command: true, shift: true, option: false, control: false)
            case .useSelectionForFind:
                return StoredShortcut(key: "e", command: true, shift: false, option: false, control: false)
            case .toggleBrowserDeveloperTools:
                // Safari default: Show Web Inspector.
                return StoredShortcut(key: "i", command: true, shift: false, option: true, control: false)
            case .showBrowserJavaScriptConsole:
                // Safari default: Show JavaScript Console.
                return StoredShortcut(key: "c", command: true, shift: false, option: true, control: false)
            case .toggleReactGrab:
                return StoredShortcut(key: "g", command: true, shift: true, option: false, control: false)
            }
        }

        func tooltip(_ base: String) -> String {
            "\(base) (\(displayedShortcutString(for: KeyboardShortcutSettings.shortcut(for: self))))"
        }

        var usesNumberedDigitMatching: Bool {
            switch self {
            case .selectSurfaceByNumber, .selectWorkspaceByNumber:
                return true
            default:
                return false
            }
        }

        func displayedShortcutString(for shortcut: StoredShortcut) -> String {
            if usesNumberedDigitMatching {
                return shortcut.numberedDisplayString
            }
            return shortcut.displayString
        }

        func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
            switch self {
            case .showHideAllWindows:
                return KeyboardShortcutSettings.normalizedSystemWideHotkeyShortcut(shortcut)
            case .selectSurfaceByNumber, .selectWorkspaceByNumber:
                let digitSource = shortcut.secondStroke ?? shortcut.firstStroke
                guard let digit = Int(digitSource.key), (1...9).contains(digit) else {
                    return nil
                }
                var normalized = shortcut
                if shortcut.hasChord {
                    normalized.chordKey = "1"
                } else {
                    normalized.key = "1"
                }
                return normalized
            default:
                return shortcut
            }
        }
    }

    private static func normalizedSystemWideHotkeyShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        guard !shortcut.hasChord,
              shortcut.hasPrimaryModifier,
              shortcut.carbonHotKeyRegistration != nil,
              !systemWideHotkeyConflicts(with: shortcut) else {
            return nil
        }
        return shortcut
    }

    private static func systemWideHotkeyConflicts(with shortcut: StoredShortcut) -> Bool {
        guard let registration = shortcut.carbonHotKeyRegistration else { return false }
        let keyCode = UInt16(registration.keyCode)
        let modifierFlags = shortcut.modifierFlags
        // Validate against the keystroke AppKit shortcuts would see for the
        // registered Carbon hotkey under the current input source.
        let eventCharacter = KeyboardLayout.character(forKeyCode: keyCode)

        return reservedSystemWideHotkeyShortcuts().contains { reserved in
            reserved.matches(
                keyCode: keyCode,
                modifierFlags: modifierFlags,
                eventCharacter: eventCharacter
            )
        }
    }

    private static func reservedSystemWideHotkeyShortcuts() -> [StoredShortcut] {
        var reserved: [StoredShortcut] = []

        for action in Action.allCases where action != .showHideAllWindows {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            if shortcut.hasChord {
                reserved.append(StoredShortcut(first: shortcut.firstStroke))
                continue
            }
            if action.usesNumberedDigitMatching {
                let stroke = shortcut.firstStroke
                reserved.append(
                    contentsOf: (1...9).map { digit in
                        StoredShortcut(
                            key: String(digit),
                            command: stroke.command,
                            shift: stroke.shift,
                            option: stroke.option,
                            control: stroke.control
                        )
                    }
                )
                continue
            }
            reserved.append(shortcut)
        }

        reserved.append(contentsOf: hardcodedSystemWideHotkeyConflicts)
        return reserved
    }

    private static let hardcodedSystemWideHotkeyConflicts: [StoredShortcut] = [
        StoredShortcut(key: "d", command: true, shift: false, option: false, control: false),
        StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true),
        StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true),
        StoredShortcut(key: "`", command: true, shift: false, option: false, control: false),
        StoredShortcut(key: "`", command: true, shift: true, option: false, control: false),
        // Cmd+. is AppKit's standard cancel keystroke for modal alerts and
        // open/save panels. Refuse to register it as the global hotkey so the
        // first instinctive "cancel" press never hides the whole app.
        StoredShortcut(key: ".", command: true, shift: false, option: false, control: false),
    ]

    static func shortcut(for action: Action) -> StoredShortcut {
        if let managedShortcut = settingsFileStore.override(for: action) {
            return managedShortcut
        }
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func isManagedBySettingsFile(_ action: Action) -> Bool {
        settingsFileStore.isManagedByFile(action)
    }

    static func settingsFileManagedSubtitle(for action: Action) -> String? {
        guard isManagedBySettingsFile(action) else { return nil }
        return String(localized: "settings.shortcuts.managedByFile", defaultValue: "Managed in settings.json")
    }

    static func matchingCustomCommand(for event: NSEvent) -> CustomCommandBinding? {
        customCommandStore.matchingCommand(for: event)
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: Action) {
        guard !isManagedBySettingsFile(action) else { return }

        let storedShortcut: StoredShortcut
        if let normalizedShortcut = action.normalizedRecordedShortcut(shortcut) {
            storedShortcut = normalizedShortcut
        } else if action.usesNumberedDigitMatching || action == .showHideAllWindows {
            return
        } else {
            storedShortcut = shortcut
        }

        if let data = try? JSONEncoder().encode(storedShortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
        postDidChangeNotification(action: action)
    }

    static func notifySettingsFileDidChange() {
        postDidChangeNotification()
    }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        postDidChangeNotification(action: action)
    }

    static func resetAll() {
        for action in Action.allCases {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        postDidChangeNotification()
    }

    private static func postDidChangeNotification(
        action: Action? = nil,
        center: NotificationCenter = .default
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if let action {
            userInfo[actionUserInfoKey] = action.rawValue
        }
        center.post(
            name: didChangeNotification,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    // MARK: - Backwards-Compatible API (call-sites can migrate gradually)

    // Keys (used by debug socket command + UI tests)
    static let focusLeftKey = Action.focusLeft.defaultsKey
    static let focusRightKey = Action.focusRight.defaultsKey
    static let focusUpKey = Action.focusUp.defaultsKey
    static let focusDownKey = Action.focusDown.defaultsKey

    // Defaults (used by settings reset + recorder button initial title)
    static let showNotificationsDefault = Action.showNotifications.defaultShortcut
    static let jumpToUnreadDefault = Action.jumpToUnread.defaultShortcut

    static func showNotificationsShortcut() -> StoredShortcut { shortcut(for: .showNotifications) }
    static func setShowNotificationsShortcut(_ shortcut: StoredShortcut) { setShortcut(shortcut, for: .showNotifications) }

    static func jumpToUnreadShortcut() -> StoredShortcut { shortcut(for: .jumpToUnread) }
    static func setJumpToUnreadShortcut(_ shortcut: StoredShortcut) { setShortcut(shortcut, for: .jumpToUnread) }

    static func nextSidebarTabShortcut() -> StoredShortcut { shortcut(for: .nextSidebarTab) }
    static func prevSidebarTabShortcut() -> StoredShortcut { shortcut(for: .prevSidebarTab) }
    static func renameWorkspaceShortcut() -> StoredShortcut { shortcut(for: .renameWorkspace) }
    static func closeWorkspaceShortcut() -> StoredShortcut { shortcut(for: .closeWorkspace) }

    static func focusLeftShortcut() -> StoredShortcut { shortcut(for: .focusLeft) }
    static func focusRightShortcut() -> StoredShortcut { shortcut(for: .focusRight) }
    static func focusUpShortcut() -> StoredShortcut { shortcut(for: .focusUp) }
    static func focusDownShortcut() -> StoredShortcut { shortcut(for: .focusDown) }

    static func splitRightShortcut() -> StoredShortcut { shortcut(for: .splitRight) }
    static func splitDownShortcut() -> StoredShortcut { shortcut(for: .splitDown) }
    static func toggleSplitZoomShortcut() -> StoredShortcut { shortcut(for: .toggleSplitZoom) }
    static func splitBrowserRightShortcut() -> StoredShortcut { shortcut(for: .splitBrowserRight) }
    static func splitBrowserDownShortcut() -> StoredShortcut { shortcut(for: .splitBrowserDown) }

    static func nextSurfaceShortcut() -> StoredShortcut { shortcut(for: .nextSurface) }
    static func prevSurfaceShortcut() -> StoredShortcut { shortcut(for: .prevSurface) }
    static func selectSurfaceByNumberShortcut() -> StoredShortcut { shortcut(for: .selectSurfaceByNumber) }
    static func newSurfaceShortcut() -> StoredShortcut { shortcut(for: .newSurface) }
    static func selectWorkspaceByNumberShortcut() -> StoredShortcut { shortcut(for: .selectWorkspaceByNumber) }

    static func openBrowserShortcut() -> StoredShortcut { shortcut(for: .openBrowser) }
    static func toggleBrowserDeveloperToolsShortcut() -> StoredShortcut { shortcut(for: .toggleBrowserDeveloperTools) }
    static func showBrowserJavaScriptConsoleShortcut() -> StoredShortcut { shortcut(for: .showBrowserJavaScriptConsole) }
}

enum SystemWideHotkeySettings {
    static let enabledKey = "systemWideHotkey.enabled"
    static let legacyShortcutKey = "systemWideHotkey.shortcut"
    static let defaultEnabled = false
    static let action: KeyboardShortcutSettings.Action = .showHideAllWindows

    static var defaultShortcut: StoredShortcut { action.defaultShortcut }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func shortcut() -> StoredShortcut {
        migrateLegacyShortcutIfNeeded()
        return storedShortcut() ?? defaultShortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut) {
        migrateLegacyShortcutIfNeeded()
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
    }

    static func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        action.normalizedRecordedShortcut(shortcut)
    }

    static func isManagedBySettingsFile() -> Bool {
        KeyboardShortcutSettings.isManagedBySettingsFile(action)
    }

    static func settingsFileManagedSubtitle() -> String? {
        KeyboardShortcutSettings.settingsFileManagedSubtitle(for: action)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: legacyShortcutKey)
        defaults.removeObject(forKey: action.defaultsKey)
    }

    private static func migrateLegacyShortcutIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacyShortcutKey) != nil else { return }
        defer { defaults.removeObject(forKey: legacyShortcutKey) }

        guard defaults.object(forKey: action.defaultsKey) == nil,
              let data = defaults.data(forKey: legacyShortcutKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return
        }

        let migratedShortcut = normalizedRecordedShortcut(shortcut) ?? shortcut
        guard let migratedData = try? JSONEncoder().encode(migratedShortcut) else { return }
        defaults.set(migratedData, forKey: action.defaultsKey)
    }

    private static func storedShortcut(defaults: UserDefaults = .standard) -> StoredShortcut? {
        if let managedShortcut = KeyboardShortcutSettings.settingsFileStore.override(for: action) {
            return managedShortcut
        }
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return nil
        }
        return shortcut
    }
}

struct CarbonHotKeyRegistration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

final class SystemWideHotkeyController {
    static let shared = SystemWideHotkeyController()
    private static let hotKeySignature: OSType = 0x434D484B // "CMHK"
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    private var recorderObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var isEnabled = SystemWideHotkeySettings.defaultEnabled
    private var shortcut = SystemWideHotkeySettings.defaultShortcut
    private var registeredShortcut: StoredShortcut?
    private var registeredHotKeyRegistration: CarbonHotKeyRegistration?
    private var hiddenWindowRestoreTargets: [NSWindow] = []

    private init() {}

    func start() {
        guard defaultsObserver == nil else { return }

        installHotKeyHandlerIfNeeded()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        recorderObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutRecorderActivity.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        appHideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.captureHiddenWindowRestoreTargets()
        }

        refreshRegistration()
    }

    private func refreshRegistration() {
        isEnabled = SystemWideHotkeySettings.isEnabled()
        shortcut = SystemWideHotkeySettings.shortcut()
        let isShortcutRecordingActive = KeyboardShortcutRecorderActivity.isAnyRecorderActive

        guard isEnabled, !isShortcutRecordingActive else {
            unregisterHotKey()
            return
        }

        guard let normalizedShortcut = SystemWideHotkeySettings.action.normalizedRecordedShortcut(shortcut),
              let registration = normalizedShortcut.carbonHotKeyRegistration else {
            unregisterHotKey()
            return
        }

        if registeredShortcut == normalizedShortcut,
           registeredHotKeyRegistration == registration,
           hotKeyRef != nil {
            return
        }

        unregisterHotKey()
        installHotKeyHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            registration.keyCode,
            registration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
#if DEBUG
            dlog(
                "globalHotkey.register failed shortcut=\(normalizedShortcut.displayString) " +
                "keyCode=\(registration.keyCode) modifiers=\(registration.modifiers) status=\(status)"
            )
#endif
            return
        }

        self.hotKeyRef = hotKeyRef
        registeredShortcut = normalizedShortcut
        registeredHotKeyRegistration = registration

#if DEBUG
        dlog(
            "globalHotkey.register success shortcut=\(normalizedShortcut.displayString) " +
            "keyCode=\(registration.keyCode) modifiers=\(registration.modifiers)"
        )
#endif
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            userInfo,
            &hotKeyHandler
        )

#if DEBUG
        if status != noErr {
            dlog("globalHotkey.handlerInstall failed status=\(status)")
        }
#endif
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredShortcut = nil
        registeredHotKeyRegistration = nil
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userInfo in
        guard let userInfo else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<SystemWideHotkeyController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return controller.handleHotKeyEvent(event)
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == Self.hotKeySignature,
              hotKeyID.id == Self.hotKeyID else {
            return OSStatus(eventNotHandledErr)
        }

#if DEBUG
        dlog("globalHotkey.fire shortcut=\(shortcut.displayString) active=\(NSApp.isActive ? 1 : 0)")
#endif

        DispatchQueue.main.async { [weak self] in
            self?.toggleApplicationVisibility()
        }
        return OSStatus(noErr)
    }

    private func toggleApplicationVisibility() {
        // Only treat the hotkey as a "hide" toggle when cmux itself is the
        // frontmost app and has at least one visible window. If the user
        // pressed the hotkey from another app, cmux is not frontmost (even if
        // some of its windows are still on screen) and the expected behavior
        // is to bring cmux forward, not hide it.
        let isFrontmost = NSApp.isActive && !NSApp.isHidden
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
        if isFrontmost && hasVisibleWindow {
            captureHiddenWindowRestoreTargets()
            NSApp.hide(nil)
            return
        }

        showAllApplicationWindows()
    }

    private func captureHiddenWindowRestoreTargets() {
        hiddenWindowRestoreTargets = NSApp.windows.filter { $0.isVisible || $0.isMiniaturized }
    }

    private func showAllApplicationWindows() {
        let allWindows = NSApp.windows
        let revealTargets: [NSWindow]

        if NSApp.isHidden {
            NSApp.unhide(nil)
            let capturedTargets = hiddenWindowRestoreTargets.filter { window in
                allWindows.contains { $0 === window }
            }
            hiddenWindowRestoreTargets.removeAll()
            revealTargets = capturedTargets.isEmpty
                ? allWindows.filter(\.isMiniaturized)
                : capturedTargets
        } else {
            revealTargets = allWindows.filter { $0.isVisible || $0.isMiniaturized }
        }

        guard !revealTargets.isEmpty else { return }

        for window in revealTargets where window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        let focusWindow = preferredFocusWindow(from: revealTargets)
        focusWindow?.makeKeyAndOrderFront(nil)

        for window in revealTargets where window !== focusWindow {
            window.orderFrontRegardless()
        }
    }

    private func preferredFocusWindow(from windows: [NSWindow]) -> NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           windows.contains(where: { $0 === keyWindow }) {
            return keyWindow
        }

        if let mainWindow = NSApp.mainWindow,
           windows.contains(where: { $0 === mainWindow }) {
            return mainWindow
        }

        return windows.first(where: \.canBecomeMain)
            ?? windows.first(where: \.canBecomeKey)
            ?? windows.first
    }
}

struct ShortcutStroke: Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
    }

    var displayString: String {
        modifierDisplayString + keyDisplayString
    }

    var modifierDisplayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }

    var keyDisplayString: String {
        switch key {
        case "\t":
            return String(localized: "shortcut.key.tab", defaultValue: "Tab")
        case "\r":
            return "↩"
        default:
            return key.uppercased()
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var hasPrimaryModifier: Bool {
        command || option || control
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "←":
            return .leftArrow
        case "→":
            return .rightArrow
        case "↑":
            return .upArrow
        case "↓":
            return .downArrow
        case "\t":
            return .tab
        case "\r":
            return KeyEquivalent(Character("\r"))
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if command {
            modifiers.insert(.command)
        }
        if shift {
            modifiers.insert(.shift)
        }
        if option {
            modifiers.insert(.option)
        }
        if control {
            modifiers.insert(.control)
        }
        return modifiers
    }

    var menuItemKeyEquivalent: String? {
        switch key {
        case "←":
            guard let scalar = UnicodeScalar(NSLeftArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "→":
            guard let scalar = UnicodeScalar(NSRightArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↑":
            guard let scalar = UnicodeScalar(NSUpArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↓":
            guard let scalar = UnicodeScalar(NSDownArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "\t":
            return "\t"
        case "\r":
            return "\r"
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    static func isEscapeCancelEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            return true
        }

        let escapeScalar = UnicodeScalar(0x1B)!
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let shouldTreatEscapeCharacterAsCancel = normalizedFlags.isEmpty || event.keyCode == 36 || event.keyCode == 76

        if shouldTreatEscapeCharacterAsCancel,
           event.characters?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        if shouldTreatEscapeCharacterAsCancel,
           event.charactersIgnoringModifiers?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        return false
    }

    static func from(event: NSEvent, requireModifier: Bool = true) -> ShortcutStroke? {
        guard !isEscapeCancelEvent(event),
              let key = storedKey(from: event) else { return nil }

        let flags = normalizedModifierFlags(from: event.modifierFlags)

        let stroke = ShortcutStroke(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            keyCode: event.keyCode
        )

        if requireModifier,
           !stroke.command && !stroke.shift && !stroke.option && !stroke.control {
            return nil
        }
        return stroke
    }

    static func parse(rawValue: String) -> ShortcutStroke? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, let lastPart = parts.last, !lastPart.isEmpty else {
            return nil
        }

        var command = false
        var shift = false
        var option = false
        var control = false

        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }

        guard let key = parseKeyToken(String(lastPart)) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    static func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        matches(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            eventCharacter: event.charactersIgnoringModifiers,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        let flags = Self.normalizedModifierFlags(from: modifierFlags)
        guard flags == self.modifierFlags else { return false }

        let shortcutKey = key.lowercased()
        if shortcutKey == "\r" {
            return keyCode == 36 || keyCode == 76
        }

        if Self.shortcutCharacterMatches(
            eventCharacter: eventCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: keyCode
        ) {
            return true
        }

        let hasEventChars = !(eventCharacter?.isEmpty ?? true)
        let eventCharsAreASCII = eventCharacter?.allSatisfy(\.isASCII) ?? true
        let shortcutKeyIsDigit = shortcutKey.count == 1 && shortcutKey.first?.isNumber == true
        if shortcutKeyIsDigit,
           hasEventChars,
           eventCharsAreASCII,
           Self.digitForNumberKeyCode(keyCode) == nil {
            return false
        }
        if hasEventChars,
           eventCharsAreASCII,
           flags.contains(.command),
           !flags.contains(.control),
           Self.shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey) {
            return false
        }

        let layoutCharacter = layoutCharacterProvider(keyCode, modifierFlags)
        if Self.shortcutCharacterMatches(
            eventCharacter: layoutCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: false,
            eventKeyCode: keyCode
        ) {
            return true
        }

        let allowANSIKeyCodeFallback = flags.contains(.control)
            || (flags.contains(.command)
                && !flags.contains(.control)
                && (
                    !Self.shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey)
                        || (hasEventChars && !eventCharsAreASCII)
                        || (!hasEventChars && (layoutCharacter?.isEmpty ?? true))
                ))
        if allowANSIKeyCodeFallback,
           let expectedKeyCode = Self.keyCodeForShortcutKey(shortcutKey) {
            return keyCode == expectedKeyCode
        }

        return false
    }

    private static func storedKey(from event: NSEvent) -> String? {
        storedKey(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
    }

    private static func storedKey(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?
    ) -> String? {
        // Prefer keyCode mapping so shifted symbol keys (e.g. "}") record as "]".
        switch keyCode {
        case 123: return "←" // left arrow
        case 124: return "→" // right arrow
        case 125: return "↓" // down arrow
        case 126: return "↑" // up arrow
        case 48: return "\t" // tab
        case 36, 76: return "\r" // return, keypad enter
        case 33: return "["  // kVK_ANSI_LeftBracket
        case 30: return "]"  // kVK_ANSI_RightBracket
        case 27: return "-"  // kVK_ANSI_Minus
        case 24: return "="  // kVK_ANSI_Equal
        case 43: return ","  // kVK_ANSI_Comma
        case 47: return "."  // kVK_ANSI_Period
        case 44: return "/"  // kVK_ANSI_Slash
        case 41: return ";"  // kVK_ANSI_Semicolon
        case 39: return "'"  // kVK_ANSI_Quote
        case 50: return "`"  // kVK_ANSI_Grave
        case 42: return "\\" // kVK_ANSI_Backslash
        default:
            break
        }

        guard let chars = charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else {
            return nil
        }

        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }

    static func parseKeyToken(_ rawValue: String) -> String? {
        let lowered = rawValue.lowercased()
        switch lowered {
        case "left", "arrowleft", "leftarrow", "←":
            return "←"
        case "right", "arrowright", "rightarrow", "→":
            return "→"
        case "up", "arrowup", "uparrow", "↑":
            return "↑"
        case "down", "arrowdown", "downarrow", "↓":
            return "↓"
        case "tab":
            return "\t"
        case "return", "enter", "↩":
            return "\r"
        case "space":
            return " "
        case "comma":
            return ","
        case "period", "dot":
            return "."
        case "slash":
            return "/"
        case "backslash":
            return "\\"
        case "semicolon":
            return ";"
        case "quote", "apostrophe":
            return "'"
        case "backtick", "grave":
            return "`"
        case "minus", "hyphen":
            return "-"
        case "plus", "equals":
            return "="
        case "leftbracket", "openbracket":
            return "["
        case "rightbracket", "closebracket":
            return "]"
        default:
            let normalized = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count == 1 else { return nil }
            return normalized
        }
    }

    static func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    private static func shouldRequireCharacterMatchForCommandShortcut(shortcutKey: String) -> Bool {
        guard shortcutKey.count == 1, let scalar = shortcutKey.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    private static func shortcutCharacterMatches(
        eventCharacter: String?,
        shortcutKey: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Bool {
        guard let eventCharacter, !eventCharacter.isEmpty else { return false }
        return normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        ) == shortcutKey
    }

    private static func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        switch key {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "\t": return 48
        case "`": return 50
        case "\r": return 36
        case "←": return 123
        case "→": return 124
        case "↓": return 125
        case "↑": return 126
        default:
            return nil
        }
    }

    private static func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default:
            return nil
        }
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if command { modifiers |= UInt32(cmdKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        if option { modifiers |= UInt32(optionKey) }
        if control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    func resolvedKeyCode(
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> UInt16? {
        if let keyCode {
            return keyCode
        }

        let shortcutKey = key.lowercased()
        let flags = modifierFlags
        let applyShiftNormalization = flags.contains(.shift)

        for candidateKeyCode in Self.supportedShortcutKeyCodes {
            let candidateCharacter = layoutCharacterProvider(candidateKeyCode, flags)
            if Self.shortcutCharacterMatches(
                eventCharacter: candidateCharacter,
                shortcutKey: shortcutKey,
                applyShiftSymbolNormalization: applyShiftNormalization,
                eventKeyCode: candidateKeyCode
            ) {
                return candidateKeyCode
            }
        }

        return Self.keyCodeForShortcutKey(shortcutKey)
    }

    var carbonHotKeyRegistration: CarbonHotKeyRegistration? {
        guard let keyCode = resolvedKeyCode() else { return nil }
        return CarbonHotKeyRegistration(keyCode: UInt32(keyCode), modifiers: carbonModifiers)
    }

    private static let supportedShortcutKeyCodes: [UInt16] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        50, 123, 124, 125, 126,
    ]
}

/// A keyboard shortcut that can be stored in UserDefaults
struct StoredShortcut: Codable, Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?
    var chordKey: String?
    var chordCommand: Bool
    var chordShift: Bool
    var chordOption: Bool
    var chordControl: Bool
    var chordKeyCode: UInt16?

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        keyCode: UInt16? = nil,
        chordKey: String? = nil,
        chordCommand: Bool = false,
        chordShift: Bool = false,
        chordOption: Bool = false,
        chordControl: Bool = false,
        chordKeyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
        self.chordKey = chordKey?.isEmpty == true ? nil : chordKey
        self.chordCommand = chordCommand
        self.chordShift = chordShift
        self.chordOption = chordOption
        self.chordControl = chordControl
        self.chordKeyCode = chordKeyCode
    }

    init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.init(
            key: first.key,
            command: first.command,
            shift: first.shift,
            option: first.option,
            control: first.control,
            keyCode: first.keyCode,
            chordKey: second?.key,
            chordCommand: second?.command ?? false,
            chordShift: second?.shift ?? false,
            chordOption: second?.option ?? false,
            chordControl: second?.control ?? false,
            chordKeyCode: second?.keyCode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case command
        case shift
        case option
        case control
        case keyCode
        case chordKey
        case chordCommand
        case chordShift
        case chordOption
        case chordControl
        case chordKeyCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            command: try container.decode(Bool.self, forKey: .command),
            shift: try container.decode(Bool.self, forKey: .shift),
            option: try container.decode(Bool.self, forKey: .option),
            control: try container.decode(Bool.self, forKey: .control),
            keyCode: try container.decodeIfPresent(UInt16.self, forKey: .keyCode),
            chordKey: try container.decodeIfPresent(String.self, forKey: .chordKey),
            chordCommand: try container.decodeIfPresent(Bool.self, forKey: .chordCommand) ?? false,
            chordShift: try container.decodeIfPresent(Bool.self, forKey: .chordShift) ?? false,
            chordOption: try container.decodeIfPresent(Bool.self, forKey: .chordOption) ?? false,
            chordControl: try container.decodeIfPresent(Bool.self, forKey: .chordControl) ?? false,
            chordKeyCode: try container.decodeIfPresent(UInt16.self, forKey: .chordKeyCode)
        )
    }

    var firstStroke: ShortcutStroke {
        ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }

    var secondStroke: ShortcutStroke? {
        guard let chordKey else { return nil }
        return ShortcutStroke(
            key: chordKey,
            command: chordCommand,
            shift: chordShift,
            option: chordOption,
            control: chordControl,
            keyCode: chordKeyCode
        )
    }

    var hasChord: Bool {
        secondStroke != nil
    }

    var displayString: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.displayString)"
        }
        return firstStroke.displayString
    }

    var numberedDisplayString: String {
        if hasChord {
            return numberedDigitHintPrefix + "1…9"
        }
        return firstStroke.modifierDisplayString + "1…9"
    }

    var numberedDigitHintPrefix: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.modifierDisplayString)"
        }
        return firstStroke.modifierDisplayString
    }

    var modifierDisplayString: String {
        firstStroke.modifierDisplayString
    }

    var keyDisplayString: String {
        firstStroke.keyDisplayString
    }

    var modifierFlags: NSEvent.ModifierFlags {
        firstStroke.modifierFlags
    }

    var hasPrimaryModifier: Bool {
        firstStroke.hasPrimaryModifier
    }

    var keyEquivalent: KeyEquivalent? {
        guard !hasChord else { return nil }
        return firstStroke.keyEquivalent
    }

    var eventModifiers: SwiftUI.EventModifiers {
        firstStroke.eventModifiers
    }

    var menuItemKeyEquivalent: String? {
        guard !hasChord else { return nil }
        return firstStroke.menuItemKeyEquivalent
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let stroke = ShortcutStroke.from(event: event) else { return nil }
        return StoredShortcut(first: stroke)
    }

    static func parse(rawValue: String) -> StoredShortcut? {
        parse(strokes: [rawValue])
    }

    static func parse(strokes: [String]) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        let parsedStrokes = strokes.compactMap(ShortcutStroke.parse(rawValue:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        guard !firstStroke.modifierFlags.isEmpty else { return nil }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        guard !hasChord else { return false }
        return firstStroke.matches(event: event, layoutCharacterProvider: layoutCharacterProvider)
    }

    func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        guard !hasChord else { return false }
        return firstStroke.matches(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventCharacter: eventCharacter,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    var carbonHotKeyRegistration: CarbonHotKeyRegistration? {
        guard !hasChord else { return nil }
        return firstStroke.carbonHotKeyRegistration
    }
}

private enum KeyboardShortcutRecorderActivity {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityDidChange")
    private static var activeRecorderCount = 0

    static var isAnyRecorderActive: Bool {
        activeRecorderCount > 0
    }

    static func beginRecording(center: NotificationCenter = .default) {
        let wasActive = isAnyRecorderActive
        activeRecorderCount += 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

    static func endRecording(center: NotificationCenter = .default) {
        guard activeRecorderCount > 0 else { return }
        let wasActive = isAnyRecorderActive
        activeRecorderCount -= 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }
}

/// View for recording a keyboard shortcut
struct KeyboardShortcutRecorder: View {
    let label: String
    var subtitle: String? = nil
    @Binding var shortcut: StoredShortcut
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var transformRecordedShortcut: (StoredShortcut) -> StoredShortcut? = { $0 }
    var isDisabled: Bool = false
    var onRecordingChanged: (Bool) -> Void = { _ in }
    @State private var isRecording = false

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            ShortcutRecorderButton(
                shortcut: $shortcut,
                isRecording: $isRecording,
                displayString: displayString,
                transformRecordedShortcut: transformRecordedShortcut,
                onRecordingChanged: onRecordingChanged
            )
                .frame(width: 160)
                .disabled(isDisabled)
        }
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut
    @Binding var isRecording: Bool
    let displayString: (StoredShortcut) -> String
    let transformRecordedShortcut: (StoredShortcut) -> StoredShortcut?
    let onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
        button.displayString = displayString
        button.transformRecordedShortcut = transformRecordedShortcut
        button.onShortcutRecorded = { newShortcut in
            shortcut = newShortcut
            isRecording = false
        }
        button.onRecordingChanged = { recording in
            isRecording = recording
            onRecordingChanged(recording)
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderNSButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.displayString = displayString
        nsView.transformRecordedShortcut = transformRecordedShortcut
        nsView.onRecordingChanged = { recording in
            isRecording = recording
            onRecordingChanged(recording)
        }
        nsView.updateTitle()
    }
}

final class ShortcutRecorderNSButton: NSButton {
    var shortcut: StoredShortcut = KeyboardShortcutSettings.showNotificationsDefault
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var transformRecordedShortcut: (StoredShortcut) -> StoredShortcut? = { $0 }
    var onShortcutRecorded: ((StoredShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var isRecording = false
    private var eventMonitor: Any?
    private var pendingChordStart: ShortcutStroke?
    private var hasRegisteredRecordingActivity = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    func updateTitle() {
        if isRecording {
            if let pendingChordStart {
                let format = String(localized: "shortcut.recorder.pendingChord", defaultValue: "%@ …")
                title = String.localizedStringWithFormat(format, pendingChordStart.displayString)
            } else {
                title = String(localized: "shortcut.pressShortcut.prompt", defaultValue: "Press shortcut…")
            }
        } else {
            title = displayString(shortcut)
        }
    }

    @objc private func buttonClicked() {
        if isRecording {
            if let pendingChordStart {
                let storedShortcut = StoredShortcut(first: pendingChordStart)
                guard let transformedShortcut = transformRecordedShortcut(storedShortcut) else {
                    NSSound.beep()
                    stopRecording()
                    return
                }
                shortcut = transformedShortcut
                onShortcutRecorded?(transformedShortcut)
            }
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        pendingChordStart = nil
        registerRecordingActivityIfNeeded()
        onRecordingChanged?(true)
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if ShortcutStroke.isEscapeCancelEvent(event) {
                self.stopRecording()
                return nil
            }

            if self.pendingChordStart == nil {
                guard let firstStroke = ShortcutStroke.from(event: event, requireModifier: true) else {
                    return nil
                }
                self.pendingChordStart = firstStroke
                self.updateTitle()
                return nil
            }

            guard let pendingChordStart = self.pendingChordStart else {
                return nil
            }

            if let secondStroke = ShortcutStroke.from(event: event, requireModifier: false) {
                let newShortcut = StoredShortcut(first: pendingChordStart, second: secondStroke)
                guard let transformedShortcut = self.transformRecordedShortcut(newShortcut) else {
                    NSSound.beep()
                    return nil
                }
                self.shortcut = transformedShortcut
                self.onShortcutRecorded?(transformedShortcut)
                self.stopRecording()
                return nil
            }

            // Consume unsupported keys while recording to avoid triggering app shortcuts.
            return nil
        }

        // Also stop recording if window loses focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        pendingChordStart = nil
        unregisterRecordingActivityIfNeeded()
        onRecordingChanged?(false)
        updateTitle()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResigned() {
        stopRecording()
    }

    private func registerRecordingActivityIfNeeded() {
        guard !hasRegisteredRecordingActivity else { return }
        hasRegisteredRecordingActivity = true
        KeyboardShortcutRecorderActivity.beginRecording()
    }

    private func unregisterRecordingActivityIfNeeded() {
        guard hasRegisteredRecordingActivity else { return }
        hasRegisteredRecordingActivity = false
        KeyboardShortcutRecorderActivity.endRecording()
    }

#if DEBUG
    var debugIsRecording: Bool {
        isRecording
    }

    func debugSetPendingChordStart(_ stroke: ShortcutStroke?) {
        isRecording = true
        pendingChordStart = stroke
        updateTitle()
    }
#endif

    deinit {
        stopRecording()
    }
}
