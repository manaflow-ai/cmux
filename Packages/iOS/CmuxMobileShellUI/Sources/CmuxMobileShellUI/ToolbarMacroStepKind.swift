#if os(iOS)
import CmuxMobileSupport

enum ToolbarMacroStepKind: String, CaseIterable, Identifiable {
    case text
    case keyCombo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:
            L10n.string("mobile.toolbar.editor.stepText", defaultValue: "Text")
        case .keyCombo:
            L10n.string("mobile.toolbar.editor.stepKeyCombo", defaultValue: "Key Combo")
        }
    }
}
#endif
