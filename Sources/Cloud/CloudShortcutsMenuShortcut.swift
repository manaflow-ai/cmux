import SwiftUI

extension KeyboardShortcutSettings.Action {
    /// Cloud shortcuts that live only in the Cloud menu, so the main-menu Cloud
    /// menu shows them. New Cloud Workspace and New Cloud Machine keep their
    /// key equivalents in the File menu, and one key never sits on two items.
    var isCloudMenuOwnedShortcut: Bool {
        switch self {
        case .openRepositoryInCloud, .openCloudSecrets, .toggleCloudPanel: return true
        default: return false
        }
    }
}

extension View {
    /// Shows a Cloud-menu-owned shortcut on a main-menu Cloud item, reading
    /// the live binding so a rebind in Settings or cmux.json shows the next
    /// time the menu draws. Chords and unbound shortcuts show nothing.
    @MainActor
    @ViewBuilder
    func cloudMenuOwnedShortcut(_ action: KeyboardShortcutSettings.Action?) -> some View {
        if let action, action.isCloudMenuOwnedShortcut,
           case let shortcut = KeyboardShortcutSettings.menuShortcut(for: action),
           !shortcut.hasChord, let key = shortcut.keyEquivalent {
            keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}
