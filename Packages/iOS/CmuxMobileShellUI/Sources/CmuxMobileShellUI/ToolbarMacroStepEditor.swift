#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct ToolbarMacroStepEditor: View {
    @Binding var step: ToolbarMacroStepDraft

    var body: some View {
        Picker(
            L10n.string("mobile.toolbar.editor.stepType", defaultValue: "Step Type"),
            selection: $step.kind
        ) {
            ForEach(ToolbarMacroStepKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)

        switch step.kind {
        case .text:
            TextField(
                L10n.string("mobile.toolbar.editor.textPlaceholder", defaultValue: "Text to type"),
                text: $step.text,
                axis: .vertical
            )
            .lineLimit(1...4)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .monospaced))

            Toggle(
                L10n.string("mobile.toolbar.editor.pressReturn", defaultValue: "Press Return"),
                isOn: $step.runAfterTyping
            )
        case .keyCombo:
            ToolbarKeyComboFields(modifiers: $step.modifiers, key: $step.key)
            if !step.hasSupportedOutput {
                Text(L10n.string(
                    "mobile.toolbar.editor.unsupportedCombo",
                    defaultValue: "This key combo is not supported yet."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
