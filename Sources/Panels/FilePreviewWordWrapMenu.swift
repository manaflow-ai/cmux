import AppKit
import SwiftUI

/// View-menu projection of the shared preference and the focused editor action.
struct FilePreviewWordWrapMenu: View {
    let shortcut: StoredShortcut
    let target: () -> SavingTextView?
    @AppStorage(FilePreviewWordWrapSettings.key) private var isOn = FilePreviewWordWrapSettings.defaultEnabled

    var body: some View {
        if let key = shortcut.keyEquivalent {
            toggle.keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(
            String(localized: "menu.view.toggleFileEditorWordWrap", defaultValue: "Toggle File Editor Word Wrap"),
            isOn: Binding(get: { isOn }, set: { _ in _ = target()?.toggleFilePreviewWordWrap() })
        )
        .disabled(target() == nil)
    }
}
