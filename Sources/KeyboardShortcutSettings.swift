import AppKit
import Bonsplit
import Carbon
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
    static let actionUserInfoKey = "action"
    static var settingsFileStore: KeyboardShortcutSettingsFileStore = .shared {
        didSet { notifySettingsFileDidChange() }
    }
    #if DEBUG
    static var shortcutLookupObserver: ((Action) -> Void)?
    #endif

    static var publicShortcutActions: [Action] {
        Action.allCases.filter(\.isPublicShortcutAction)
    }

    static var settingsVisibleActions: [Action] {
        orderedSettingsVisibleActions(
            from: publicShortcutActions.filter { $0 != .showHideAllWindows }
        )
    }

    private static func orderedSettingsVisibleActions(from actions: [Action]) -> [Action] {
        let colocatedSidebarActions = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .findInDirectory,
        ].filter(actions.contains)
        let actionSet = Set(colocatedSidebarActions)
        let baseActions = actions.filter { !actionSet.contains($0) }

        guard let anchorIndex = baseActions.firstIndex(of: .markOldestUnreadAndJumpNext)
            ?? baseActions.firstIndex(of: .jumpToUnread) else {
            return colocatedSidebarActions + baseActions
        }

        var orderedActions = baseActions
        orderedActions.insert(contentsOf: colocatedSidebarActions, at: anchorIndex + 1)
        return orderedActions
    }

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

}

