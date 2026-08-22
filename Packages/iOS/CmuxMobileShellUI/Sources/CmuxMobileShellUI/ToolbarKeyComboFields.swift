#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import SwiftUI

struct ToolbarKeyComboFields: View {
    @Binding var modifiers: TerminalKeyModifier
    @Binding var key: TerminalSpecialKey

    var body: some View {
        Toggle(
            L10n.string("mobile.toolbar.editor.modifier.shift", defaultValue: "Shift"),
            isOn: binding(for: .shift)
        )
        Toggle(
            L10n.string("mobile.toolbar.editor.modifier.control", defaultValue: "Control"),
            isOn: binding(for: .control)
        )
        Toggle(
            L10n.string("mobile.toolbar.editor.modifier.option", defaultValue: "Option"),
            isOn: binding(for: .alternate)
        )
        Picker(L10n.string("mobile.toolbar.editor.keyPicker", defaultValue: "Key"), selection: $key) {
            ForEach(TerminalSpecialKey.toolbarEditorOptions, id: \.self) { key in
                Text(key.toolbarEditorDisplayName).tag(key)
            }
        }
    }

    private func binding(for modifier: TerminalKeyModifier) -> Binding<Bool> {
        Binding(
            get: { modifiers.contains(modifier) },
            set: { isOn in
                if isOn {
                    modifiers.insert(modifier)
                } else {
                    modifiers.remove(modifier)
                }
            }
        )
    }
}
#endif
