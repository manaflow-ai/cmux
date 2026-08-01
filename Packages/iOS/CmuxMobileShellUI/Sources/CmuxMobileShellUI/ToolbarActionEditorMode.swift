#if os(iOS)
import CmuxMobileSupport

enum ToolbarActionEditorMode: String, CaseIterable, Identifiable {
    case text
    case keyCombo
    case macro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:
            L10n.string("mobile.toolbar.editor.type.text", defaultValue: "Text")
        case .keyCombo:
            L10n.string("mobile.toolbar.editor.type.keyCombo", defaultValue: "Key Combo")
        case .macro:
            L10n.string("mobile.toolbar.editor.type.macro", defaultValue: "Macro")
        }
    }
}
#endif
