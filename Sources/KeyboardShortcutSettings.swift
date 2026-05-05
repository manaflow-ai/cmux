import AppKit
import Bonsplit
import Carbon
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
    static let actionUserInfoKey = "action"
    static let settingsFileDisplayPath = "~/.config/cmux/cmux.json"
    static var settingsFileStore: KeyboardShortcutSettingsFileStore = .shared {
        didSet { notifySettingsFileDidChange() }
    }
    #if DEBUG
    static var shortcutLookupObserver: ((Action) -> Void)?
    #endif

    enum ShortcutRecordingRejection: Equatable {
        case bareKeyNotAllowed
        case conflictsWithAction(Action)
        case reservedBySystem
        case numberedShortcutRequiresDigit
        case systemWideHotkeyRequiresModifier
    }

    enum RecordedShortcutResolution: Equatable {
        case accepted(StoredShortcut)
        case rejected(ShortcutRecordingRejection)
    }

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
        case reopenPreviousSession
        case goToWorkspace
        case commandPalette
        case commandPaletteNext
        case commandPalettePrevious
        case sendFeedback
        case showNotifications
        case jumpToUnread
        case focusRightSidebar
        case switchRightSidebarToFiles
        case switchRightSidebarToFind
        case switchRightSidebarToSessions
        case switchRightSidebarToFeed
        case switchRightSidebarToDock
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
        case splitDown, toggleSplitZoom
        case equalizeSplits
        case splitBrowserRight
        case splitBrowserDown

        // File Explorer
        case toggleFileExplorer

        // Panels
        case saveFilePreview
        case openBrowser
        case focusBrowserAddressBar
        case browserBack
        case browserForward
        case browserReload
        case browserZoomIn
        case browserZoomOut
        case browserZoomReset
        case find
        case findInDirectory
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
            case .reopenPreviousSession: return String(localized: "shortcut.reopenPreviousSession.label", defaultValue: "Reopen Previous Session")
            case .goToWorkspace: return String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…")
            case .commandPalette: return String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…")
            case .commandPaletteNext: return String(localized: "shortcut.commandPaletteNext.label", defaultValue: "Command Palette: Next")
            case .commandPalettePrevious: return String(localized: "shortcut.commandPalettePrevious.label", defaultValue: "Command Palette: Previous")
            case .sendFeedback: return String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback")
            case .showNotifications: return String(localized: "shortcut.showNotifications.label", defaultValue: "Show Notifications")
            case .jumpToUnread: return String(localized: "shortcut.jumpToUnread.label", defaultValue: "Jump to Latest Unread")
            case .focusRightSidebar: return String(localized: "shortcut.focusRightSidebar.label", defaultValue: "Focus Right Sidebar")
            case .switchRightSidebarToFiles: return String(localized: "shortcut.switchRightSidebarToFiles.label", defaultValue: "Show Sidebar Files")
            case .switchRightSidebarToFind: return String(localized: "shortcut.switchRightSidebarToFind.label", defaultValue: "Show Sidebar Find")
            case .switchRightSidebarToSessions: return String(localized: "shortcut.switchRightSidebarToSessions.label", defaultValue: "Show Sidebar Vault")
            case .switchRightSidebarToFeed: return String(localized: "shortcut.switchRightSidebarToFeed.label", defaultValue: "Show Sidebar Feed")
            case .switchRightSidebarToDock: return String(localized: "shortcut.switchRightSidebarToDock.label", defaultValue: "Show Sidebar Dock")
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
            case .equalizeSplits: return String(localized: "shortcut.equalizeSplits.label", defaultValue: "Equalize Splits")
            case .splitBrowserRight: return String(localized: "shortcut.splitBrowserRight.label", defaultValue: "Split Browser Right")
            case .splitBrowserDown: return String(localized: "shortcut.splitBrowserDown.label", defaultValue: "Split Browser Down")
            case .toggleFileExplorer: return String(localized: "shortcut.toggleFileExplorer.label", defaultValue: "Toggle File Explorer")
            case .saveFilePreview: return String(localized: "shortcut.saveFilePreview.label", defaultValue: "Save File Preview")
            case .openBrowser: return String(localized: "shortcut.openBrowser.label", defaultValue: "Open Browser")
            case .focusBrowserAddressBar: return String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")
            case .browserBack: return String(localized: "menu.view.back", defaultValue: "Back")
            case .browserForward: return String(localized: "menu.view.forward", defaultValue: "Forward")
            case .browserReload: return String(localized: "menu.view.reloadPage", defaultValue: "Reload Page")
            case .browserZoomIn: return String(localized: "menu.view.zoomIn", defaultValue: "Zoom In")
            case .browserZoomOut: return String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out")
            case .browserZoomReset: return String(localized: "menu.view.actualSize", defaultValue: "Actual Size")
            case .find: return String(localized: "menu.find.find", defaultValue: "Find…")
            case .findInDirectory: return String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…")
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
            case .reopenPreviousSession:
                return StoredShortcut(key: "o", command: true, shift: true, option: false, control: false)
            case .goToWorkspace:
                return StoredShortcut(key: "p", command: true, shift: false, option: false, control: false)
            case .commandPalette:
                return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false)
            case .commandPaletteNext:
                return StoredShortcut(key: "n", command: false, shift: false, option: false, control: true)
            case .commandPalettePrevious:
                return StoredShortcut(key: "p", command: false, shift: false, option: false, control: true)
            case .sendFeedback:
                return StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
            case .showNotifications:
                return StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
            case .jumpToUnread:
                return StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
            case .focusRightSidebar:
                return StoredShortcut(key: "e", command: true, shift: true, option: false, control: false)
            case .switchRightSidebarToFiles:
                return StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToFind:
                return StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToSessions:
                return StoredShortcut(key: "3", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToFeed:
                return StoredShortcut(key: "4", command: false, shift: false, option: false, control: true)
            case .switchRightSidebarToDock:
                return StoredShortcut(key: "5", command: false, shift: false, option: false, control: true)
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
                return StoredShortcut(key: "e", command: true, shift: false, option: true, control: false)
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
            case .splitDown: return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
            case .toggleSplitZoom: return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
            case .equalizeSplits: return StoredShortcut(key: "=", command: true, shift: false, option: false, control: true)
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
            case .saveFilePreview:
                return StoredShortcut(key: "s", command: true, shift: false, option: false, control: false)
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
            case .findInDirectory:
                return StoredShortcut(key: "f", command: true, shift: true, option: false, control: false)
            case .findNext:
                return StoredShortcut(key: "g", command: true, shift: false, option: false, control: false)
            case .findPrevious:
                return StoredShortcut(key: "g", command: true, shift: false, option: true, control: false)
            case .hideFind:
                return StoredShortcut(key: "f", command: true, shift: true, option: true, control: false)
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
            if shortcut.isUnbound {
                return shortcut.displayString
            }
            if usesNumberedDigitMatching {
                return shortcut.numberedDisplayString
            }
            return shortcut.displayString
        }

        func conflicts(
            with proposedShortcut: StoredShortcut,
            proposedAction: Action,
            configuredShortcut: StoredShortcut
        ) -> Bool {
            guard shortcutContext.overlaps(proposedAction.shortcutContext) else {
                return false
            }
            return KeyboardShortcutSettings.shortcutsConflict(
                proposedShortcut,
                proposedUsesNumberedDigitMatching: proposedAction.usesNumberedDigitMatching,
                configuredShortcut,
                configuredUsesNumberedDigitMatching: usesNumberedDigitMatching
            )
        }

        func normalizedRecordedShortcutResult(_ shortcut: StoredShortcut) -> RecordedShortcutResolution {
            if shortcut.isUnbound {
                return .accepted(.unbound)
            }

            if let conflictingAction = KeyboardShortcutSettings.conflictingAction(
                for: shortcut,
                excluding: self
            ) {
                return .rejected(.conflictsWithAction(conflictingAction))
            }

            return resolvedRecordedShortcutIgnoringConflicts(shortcut)
        }

        func normalizedSettingsFileShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
            // cmux.json can load while the global settings store is still initializing.
            // Keep this path free of conflict and hotkey checks that consult global shortcut state.
            if shortcut.isUnbound {
                return .unbound
            }

            if case let .accepted(normalized) = resolvedRecordedShortcutIgnoringConflicts(
                shortcut,
                checkingSystemWideConflicts: false
            ) {
                return normalized
            }

            return usesNumberedDigitMatching ? nil : shortcut
        }

        func resolvedRecordedShortcutIgnoringConflicts(_ shortcut: StoredShortcut, checkingSystemWideConflicts: Bool = true) -> RecordedShortcutResolution {
            if shortcut.isUnbound {
                return .accepted(.unbound)
            }

            switch self {
            case .showHideAllWindows:
                return KeyboardShortcutSettings.normalizedSystemWideHotkeyShortcutResult(shortcut, checkingConflicts: checkingSystemWideConflicts)
            case .selectSurfaceByNumber, .selectWorkspaceByNumber:
                return resolvedNumberedDigitShortcut(shortcut)
            default:
                return .accepted(shortcut)
            }
        }

        private func resolvedNumberedDigitShortcut(
            _ shortcut: StoredShortcut
        ) -> RecordedShortcutResolution {
            let digitSource = shortcut.secondStroke ?? shortcut.firstStroke
            guard let digit = Int(digitSource.key), (1...9).contains(digit) else {
                return .rejected(.numberedShortcutRequiresDigit)
            }
            var normalized = shortcut
            if shortcut.hasChord {
                normalized.chordKey = "1"
            } else {
                normalized.key = "1"
            }
            return .accepted(normalized)
        }

        func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
            guard case let .accepted(normalized) = normalizedRecordedShortcutResult(shortcut) else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedSystemWideHotkeyShortcutResult(_ shortcut: StoredShortcut, checkingConflicts: Bool = true) -> RecordedShortcutResolution {
        guard !shortcut.hasChord else {
            return .rejected(.reservedBySystem)
        }
        guard shortcut.hasPrimaryModifier else {
            return .rejected(.systemWideHotkeyRequiresModifier)
        }
        guard shortcut.carbonHotKeyRegistration != nil,
              !checkingConflicts || !systemWideHotkeyConflicts(with: shortcut) else {
            return .rejected(.reservedBySystem)
        }
        return .accepted(shortcut)
    }

    private static func normalizedSystemWideHotkeyShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        guard case let .accepted(normalized) = normalizedSystemWideHotkeyShortcutResult(shortcut) else {
            return nil
        }
        return normalized
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
            guard !shortcut.isUnbound else { continue }
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
        StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true),
        StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true),
        StoredShortcut(key: "`", command: true, shift: false, option: false, control: false),
        StoredShortcut(key: "`", command: true, shift: true, option: false, control: false),
        // Cmd+. is AppKit's standard cancel keystroke for modal alerts and
        // open/save panels. Refuse to register it as the global hotkey so the
        // first instinctive "cancel" press never hides the whole app.
        StoredShortcut(key: ".", command: true, shift: false, option: false, control: false),
    ]

    private static func conflictingAction(
        for proposedShortcut: StoredShortcut,
        excluding currentAction: Action
    ) -> Action? {
        for action in Action.allCases where action != currentAction {
            let configuredShortcut = shortcut(for: action)
            if action.conflicts(
                with: proposedShortcut,
                proposedAction: currentAction,
                configuredShortcut: configuredShortcut
            ) {
                return action
            }
        }
        return nil
    }

    private enum ShortcutConflictMatchMode {
        case exact
        case numberedDigitFamily
    }

    private static func shortcutsConflict(
        _ proposedShortcut: StoredShortcut,
        proposedUsesNumberedDigitMatching: Bool,
        _ configuredShortcut: StoredShortcut,
        configuredUsesNumberedDigitMatching: Bool
    ) -> Bool {
        guard !proposedShortcut.isUnbound, !configuredShortcut.isUnbound else {
            return false
        }

        switch (proposedShortcut.hasChord, configuredShortcut.hasChord) {
        case (false, false):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredShortcut.firstStroke,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (true, true):
            guard strokesConflict(proposedShortcut.firstStroke, configuredShortcut.firstStroke),
                  let proposedSecond = proposedShortcut.secondStroke,
                  let configuredSecond = configuredShortcut.secondStroke else {
                return false
            }
            return shortcutStrokeMatchersConflict(
                proposedSecond,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredSecond,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (true, false):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: .exact,
                configuredShortcut.firstStroke,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (false, true):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredShortcut.firstStroke,
                mode: .exact
            )
        }
    }

    private static func shortcutStrokeMatchersConflict(
        _ lhs: ShortcutStroke,
        mode lhsMode: ShortcutConflictMatchMode,
        _ rhs: ShortcutStroke,
        mode rhsMode: ShortcutConflictMatchMode
    ) -> Bool {
        switch (lhsMode, rhsMode) {
        case (.exact, .exact):
            return strokesConflict(lhs, rhs)
        case (.numberedDigitFamily, .numberedDigitFamily):
            return numberedDigitStrokeConflict(lhs, rhs)
        case (.numberedDigitFamily, .exact):
            return numberedDigitStrokeConflictsWithExactStroke(lhs, rhs)
        case (.exact, .numberedDigitFamily):
            return numberedDigitStrokeConflictsWithExactStroke(rhs, lhs)
        }
    }

    private static func numberedDigitStrokeConflictsWithExactStroke(
        _ numberedStroke: ShortcutStroke,
        _ exactStroke: ShortcutStroke
    ) -> Bool {
        guard isNumberedDigitStroke(numberedStroke), isNumberedDigitStroke(exactStroke) else {
            return false
        }
        return numberedStroke.command == exactStroke.command &&
            numberedStroke.shift == exactStroke.shift &&
            numberedStroke.option == exactStroke.option &&
            numberedStroke.control == exactStroke.control
    }

    private static func numberedDigitStrokeConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        guard isNumberedDigitStroke(lhs), isNumberedDigitStroke(rhs) else { return false }
        return lhs.command == rhs.command &&
            lhs.shift == rhs.shift &&
            lhs.option == rhs.option &&
            lhs.control == rhs.control
    }

    private static func isNumberedDigitStroke(_ stroke: ShortcutStroke) -> Bool {
        guard let digit = Int(stroke.key) else { return false }
        return (1...9).contains(digit)
    }

    private static func strokesConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        lhs.key == rhs.key &&
            lhs.command == rhs.command &&
            lhs.shift == rhs.shift &&
            lhs.option == rhs.option &&
            lhs.control == rhs.control
    }

    private static func storedShortcutForPersistence(
        _ shortcut: StoredShortcut,
        action: Action
    ) -> StoredShortcut? {
        if shortcut.isUnbound {
            return shortcut
        }

        switch action.resolvedRecordedShortcutIgnoringConflicts(shortcut) {
        case let .accepted(normalizedShortcut):
            return normalizedShortcut
        case .rejected:
            if action.usesNumberedDigitMatching || action == .showHideAllWindows {
                return nil
            }
            return shortcut
        }
    }

    private static func storedShortcutForReplacement(
        _ shortcut: StoredShortcut,
        action: Action
    ) -> StoredShortcut? {
        switch action.resolvedRecordedShortcutIgnoringConflicts(shortcut) {
        case let .accepted(normalizedShortcut):
            return normalizedShortcut
        case .rejected:
            return nil
        }
    }

    private static func persistShortcut(
        _ shortcut: StoredShortcut,
        for action: Action,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: action.defaultsKey)
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: Action) {
        guard !isManagedBySettingsFile(action) else { return }

        guard let storedShortcut = storedShortcutForPersistence(shortcut, action: action) else {
            return
        }

        persistShortcut(storedShortcut, for: action)
        postDidChangeNotification(action: action)
    }

    static func swapShortcutConflict(
        proposedShortcut: StoredShortcut,
        currentAction: Action,
        conflictingAction: Action,
        previousShortcut: StoredShortcut
    ) -> Bool {
        guard !isManagedBySettingsFile(currentAction),
              !isManagedBySettingsFile(conflictingAction),
              conflictingAction.conflicts(with: proposedShortcut, proposedAction: currentAction, configuredShortcut: shortcut(for: conflictingAction)),
              let resolvedCurrentShortcut = storedShortcutForReplacement(
                proposedShortcut,
                action: currentAction
            ),
            let resolvedConflictingShortcut = storedShortcutForReplacement(
                previousShortcut,
                action: conflictingAction
            )
        else {
            return false
        }

        persistShortcut(resolvedCurrentShortcut, for: currentAction)
        persistShortcut(resolvedConflictingShortcut, for: conflictingAction)
        postDidChangeNotification(action: currentAction)
        postDidChangeNotification(action: conflictingAction)
        return true
    }

    static func notifySettingsFileDidChange(center: NotificationCenter = .default) { postDidChangeNotification(center: center) }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        postDidChangeNotification(action: action)
    }

    static func clearShortcut(for action: Action) { setShortcut(.unbound, for: action) }

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
        if let managedShortcut = KeyboardShortcutSettings.settingsFileStore.override(for: action) {
            return managedShortcut
        }
        return storedShortcut() ?? defaultShortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut) {
        migrateLegacyShortcutIfNeeded()
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
    }

    static func normalizedRecordedShortcutResult(
        _ shortcut: StoredShortcut
    ) -> KeyboardShortcutSettings.RecordedShortcutResolution {
        action.normalizedRecordedShortcutResult(shortcut)
    }

    static func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        action.normalizedRecordedShortcut(shortcut)
    }

    static func isManagedBySettingsFile() -> Bool {
        KeyboardShortcutSettings.isManagedBySettingsFile(action)
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
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return KeyboardShortcutSettings.settingsFileStore.override(for: action)
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
            cmuxDebugLog(
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
        cmuxDebugLog(
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
            cmuxDebugLog("globalHotkey.handlerInstall failed status=\(status)")
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
        cmuxDebugLog("globalHotkey.fire shortcut=\(shortcut.displayString) active=\(NSApp.isActive ? 1 : 0)")
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

struct ShortcutStroke: Equatable, Hashable {
    enum RecordingResult: Equatable {
        case accepted(ShortcutStroke)
        case rejected(KeyboardShortcutSettings.ShortcutRecordingRejection)
        case unsupportedKey
    }

    private struct RecordableKey {
        let key: String
        let keyCode: UInt16?
    }

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
        case "space": return String(localized: "shortcut.key.space", defaultValue: "Space")
        case "\r":
            return "↩"
        case "media.brightnessDown":
            return String(localized: "shortcut.key.mediaBrightnessDown", defaultValue: "Brightness Down")
        case "media.brightnessUp":
            return String(localized: "shortcut.key.mediaBrightnessUp", defaultValue: "Brightness Up")
        case "media.mute":
            return String(localized: "shortcut.key.mediaMute", defaultValue: "Mute")
        case "media.next":
            return String(localized: "shortcut.key.mediaNext", defaultValue: "Next Track")
        case "media.playPause":
            return String(localized: "shortcut.key.mediaPlayPause", defaultValue: "Play/Pause")
        case "media.previous":
            return String(localized: "shortcut.key.mediaPrevious", defaultValue: "Previous Track")
        case "media.volumeDown":
            return String(localized: "shortcut.key.mediaVolumeDown", defaultValue: "Volume Down")
        case "media.volumeUp":
            return String(localized: "shortcut.key.mediaVolumeUp", defaultValue: "Volume Up")
        default:
            if let functionKeyDisplayString = Self.functionKeyDisplayString(for: key) {
                return functionKeyDisplayString
            }
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
        if key == "space" { return KeyEquivalent(Character(" ")) }

        if Self.usesDirectKeyCodeMatching(key) {
            return nil
        }

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
        if key == "space" { return " " }

        if Self.usesDirectKeyCodeMatching(key) {
            return nil
        }

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
        guard event.type == .keyDown || event.type == .keyUp else { return false }

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
        guard case let .accepted(stroke) = recordingResult(from: event, requireModifier: requireModifier) else {
            return nil
        }
        return stroke
    }

    static func recordingResult(
        from event: NSEvent,
        requireModifier: Bool = true
    ) -> RecordingResult {
        guard !isEscapeCancelEvent(event),
              let recordableKey = recordableKey(from: event) else {
            return .unsupportedKey
        }

        let flags = normalizedModifierFlags(from: event.modifierFlags)

        let stroke = ShortcutStroke(
            key: recordableKey.key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            keyCode: recordableKey.keyCode
        )

        if requireModifier,
           !stroke.command && !stroke.shift && !stroke.option && !stroke.control &&
           !stroke.isBareShortcutAllowedWithoutModifier {
            return .rejected(.bareKeyNotAllowed)
        }
        return .accepted(stroke)
    }

    static func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        let shortcutKey = key.lowercased()
        if shortcutKey.hasPrefix("media.") {
            guard let eventMediaKey = Self.mediaKey(from: event)?.key.lowercased() else {
                return false
            }
            return eventMediaKey == shortcutKey &&
                Self.normalizedModifierFlags(from: event.modifierFlags) == modifierFlags
        }

        guard event.type == .keyDown else { return false }

        return matches(
            keyCode: Self.recordableKey(from: event)?.keyCode ?? event.keyCode,
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
        if Self.usesDirectKeyCodeMatching(shortcutKey) {
            guard let expectedKeyCode = self.keyCode ?? Self.keyCodeForShortcutKey(shortcutKey) else {
                return false
            }
            return keyCode == expectedKeyCode
        }

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

    private var isBareShortcutAllowedWithoutModifier: Bool {
        Self.usesDirectKeyCodeMatching(key)
    }

    private static func recordableKey(from event: NSEvent) -> RecordableKey? {
        if event.type == .systemDefined {
            return mediaKey(from: event)
        }

        guard event.type == .keyDown || event.type == .keyUp else {
            return nil
        }

        if let specialKey = event.specialKey,
           let recordableKey = recordableKey(from: specialKey, eventKeyCode: event.keyCode) {
            return recordableKey
        }

        guard let storedKey = storedKey(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return nil
        }
        return RecordableKey(key: storedKey, keyCode: event.keyCode)
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
        case 49: return "space" // kVK_Space
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

    private static func recordableKey(
        from specialKey: NSEvent.SpecialKey,
        eventKeyCode: UInt16
    ) -> RecordableKey? {
        switch specialKey {
        case .f1: return RecordableKey(key: "f1", keyCode: eventKeyCode)
        case .f2: return RecordableKey(key: "f2", keyCode: eventKeyCode)
        case .f3: return RecordableKey(key: "f3", keyCode: eventKeyCode)
        case .f4: return RecordableKey(key: "f4", keyCode: eventKeyCode)
        case .f5: return RecordableKey(key: "f5", keyCode: eventKeyCode)
        case .f6: return RecordableKey(key: "f6", keyCode: eventKeyCode)
        case .f7: return RecordableKey(key: "f7", keyCode: eventKeyCode)
        case .f8: return RecordableKey(key: "f8", keyCode: eventKeyCode)
        case .f9: return RecordableKey(key: "f9", keyCode: eventKeyCode)
        case .f10: return RecordableKey(key: "f10", keyCode: eventKeyCode)
        case .f11: return RecordableKey(key: "f11", keyCode: eventKeyCode)
        case .f12: return RecordableKey(key: "f12", keyCode: eventKeyCode)
        case .f13: return RecordableKey(key: "f13", keyCode: eventKeyCode)
        case .f14: return RecordableKey(key: "f14", keyCode: eventKeyCode)
        case .f15: return RecordableKey(key: "f15", keyCode: eventKeyCode)
        case .f16: return RecordableKey(key: "f16", keyCode: eventKeyCode)
        case .f17: return RecordableKey(key: "f17", keyCode: eventKeyCode)
        case .f18: return RecordableKey(key: "f18", keyCode: eventKeyCode)
        case .f19: return RecordableKey(key: "f19", keyCode: eventKeyCode)
        case .f20: return RecordableKey(key: "f20", keyCode: eventKeyCode)
        default:
            return nil
        }
    }

    private static func mediaKey(from event: NSEvent) -> RecordableKey? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == Int16(8) else {
            return nil
        }

        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let keyCode = UInt16((data1 & 0xFFFF0000) >> 16)
        let keyState = UInt8((data1 & 0x0000FF00) >> 8)
        guard keyState == 0x0A else { return nil }

        switch keyCode {
        case 0: return RecordableKey(key: "media.volumeUp", keyCode: keyCode)
        case 1: return RecordableKey(key: "media.volumeDown", keyCode: keyCode)
        case 2: return RecordableKey(key: "media.brightnessUp", keyCode: keyCode)
        case 3: return RecordableKey(key: "media.brightnessDown", keyCode: keyCode)
        case 7: return RecordableKey(key: "media.mute", keyCode: keyCode)
        case 16: return RecordableKey(key: "media.playPause", keyCode: keyCode)
        case 17: return RecordableKey(key: "media.next", keyCode: keyCode)
        case 18: return RecordableKey(key: "media.previous", keyCode: keyCode)
        default:
            return nil
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
        case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111
        case "f13": return 105
        case "f14": return 107
        case "f15": return 113
        case "f16": return 106
        case "f17": return 64
        case "f18": return 79
        case "f19": return 80
        case "f20": return 90
        case "media.volumeUp": return 0
        case "media.volumeDown": return 1
        case "media.brightnessUp": return 2
        case "media.brightnessDown": return 3
        case "media.mute": return 7
        case "media.playPause": return 16
        case "media.next": return 17
        case "media.previous": return 18
        case "space": return 49
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

    private static func usesDirectKeyCodeMatching(_ key: String) -> Bool {
        key == "space" || functionKeyDisplayString(for: key) != nil || key.hasPrefix("media.")
    }

    private static func functionKeyDisplayString(for key: String) -> String? {
        guard key.hasPrefix("f"),
              let number = Int(key.dropFirst()),
              (1...20).contains(number) else {
            return nil
        }
        return "F\(number)"
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
        33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
        50, 123, 124, 125, 126,
    ]
}

/// A keyboard shortcut that can be stored in UserDefaults
struct StoredShortcut: Codable, Equatable, Hashable {
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

    static var unbound: StoredShortcut {
        StoredShortcut(key: "", command: false, shift: false, option: false, control: false)
    }

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

    var isUnbound: Bool {
        key.isEmpty
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
        if isUnbound {
            return String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        }
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.displayString)"
        }
        return firstStroke.displayString
    }

    var numberedDisplayString: String {
        if isUnbound {
            return displayString
        }
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
        guard !isUnbound else { return false }
        return firstStroke.hasPrimaryModifier
    }

    var keyEquivalent: KeyEquivalent? {
        guard !isUnbound, !hasChord else { return nil }
        return firstStroke.keyEquivalent
    }

    var eventModifiers: SwiftUI.EventModifiers {
        firstStroke.eventModifiers
    }

    var menuItemKeyEquivalent: String? {
        guard !isUnbound, !hasChord else { return nil }
        return firstStroke.menuItemKeyEquivalent
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let stroke = ShortcutStroke.from(event: event) else { return nil }
        return StoredShortcut(first: stroke)
    }

    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        guard !isUnbound, !hasChord else { return false }
        return firstStroke.matches(event: event, layoutCharacterProvider: layoutCharacterProvider)
    }

    func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        guard !isUnbound, !hasChord else { return false }
        return firstStroke.matches(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventCharacter: eventCharacter,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    var carbonHotKeyRegistration: CarbonHotKeyRegistration? {
        guard !isUnbound, !hasChord else { return nil }
        return firstStroke.carbonHotKeyRegistration
    }
}

extension ShortcutStroke {
    static func parseConfig(_ rawValue: String) -> ShortcutStroke? {
        guard !rawValue.isEmpty else { return nil }

        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, let lastRawPart = rawParts.last, !lastRawPart.isEmpty else {
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

        guard let key = parseConfigKeyToken(lastRawPart) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    func configString(preserveDigit: Bool = true) -> String {
        var parts: [String] = []
        if command { parts.append("cmd") }
        if shift { parts.append("shift") }
        if option { parts.append("opt") }
        if control { parts.append("ctrl") }
        parts.append(configKeyString(preserveDigit: preserveDigit))
        return parts.joined(separator: "+")
    }

    private func configKeyString(preserveDigit: Bool) -> String {
        if preserveDigit {
            return key
        }
        if let digit = Int(key), (1...9).contains(digit) {
            return "1"
        }
        return key
    }

    private static func parseConfigKeyToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return !rawValue.isEmpty && rawValue.allSatisfy { $0 == " " } ? "space" : nil
        }

        let lowered = trimmed.lowercased()
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
        case "space", "spacebar", "<space>":
            return "space"
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
        case "volumeup", "mediavolumeup", "media.volumeup":
            return "media.volumeUp"
        case "volumedown", "mediavolumedown", "media.volumedown":
            return "media.volumeDown"
        case "brightnessup", "mediabrightnessup", "media.brightnessup":
            return "media.brightnessUp"
        case "brightnessdown", "mediabrightnessdown", "media.brightnessdown":
            return "media.brightnessDown"
        case "mute", "mediamute", "media.mute":
            return "media.mute"
        case "playpause", "mediaplaypause", "media.playpause":
            return "media.playPause"
        case "nexttrack", "medianext", "media.next", "media.nexttrack":
            return "media.next"
        case "previoustrack", "mediaprevious", "media.previous", "media.previoustrack":
            return "media.previous"
        default:
            if lowered.hasPrefix("f"),
               let number = Int(lowered.dropFirst()),
               (1...20).contains(number) {
                return "f\(number)"
            }
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }
}

extension StoredShortcut {
    static func parseConfig(_ rawValue: String) -> StoredShortcut? {
        if isUnboundConfigToken(rawValue) {
            return .unbound
        }
        return parseConfig(strokes: [rawValue])
    }

    static func parseConfig(strokes: [String]) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        if strokes.count == 1, let rawValue = strokes.first, isUnboundConfigToken(rawValue) {
            return .unbound
        }
        let parsedStrokes = strokes.compactMap(ShortcutStroke.parseConfig(_:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        guard !firstStroke.modifierFlags.isEmpty || firstStroke.key == "space" else { return nil }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    var configIdentifier: String {
        if isUnbound { return "none" }
        if let secondStroke {
            return "\(firstStroke.configString()) \(secondStroke.configString())"
        }
        return firstStroke.configString()
    }

    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "none" || normalized == "clear" || normalized == "unbound" || normalized == "disabled"
    }
}

enum KeyboardShortcutRecorderActivity {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityDidChange")
    static let stopAllNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityStopAll")
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

    static func stopAllRecording(center: NotificationCenter = .default) {
        center.post(name: stopAllNotification, object: nil)
    }
}

struct ShortcutRecorderRejectedAttempt: Equatable {
    let reason: KeyboardShortcutSettings.ShortcutRecordingRejection
    let proposedShortcut: StoredShortcut?
}
