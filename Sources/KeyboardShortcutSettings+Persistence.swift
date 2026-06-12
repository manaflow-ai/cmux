import AppKit
import Bonsplit
import Carbon
import SwiftUI


// MARK: - Shortcut persistence + mutation API
extension KeyboardShortcutSettings {
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
            if action.usesNumberedDigitMatching || action == .showHideAllWindows || action == .globalSearch {
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
}
