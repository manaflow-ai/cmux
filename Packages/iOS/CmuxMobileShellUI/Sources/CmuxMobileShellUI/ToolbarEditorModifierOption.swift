import CmuxMobileSupport
import CmuxMobileTerminalKit

/// A modifier the toolbar-action editor exposes as a toggle chip, carrying its
/// on-key glyph and a localized accessibility name. The key-combo presentation
/// helpers on ``TerminalKeyModifier`` and ``TerminalSpecialKey`` live alongside
/// it so the editor's combo picker has one home.
struct ToolbarEditorModifierOption: Identifiable {
    let modifier: TerminalKeyModifier
    let glyph: String
    let name: String
    var id: Int { modifier.rawValue }
}

extension TerminalKeyModifier {
    /// The modifiers a custom key combo can carry (Shift, Control, Option),
    /// matching the subset ``TerminalKeyEncoder`` understands, as editor toggle
    /// chips in canonical ⇧⌃⌥ order.
    static var editorModifierOptions: [ToolbarEditorModifierOption] {
        [
            ToolbarEditorModifierOption(
                modifier: .shift,
                glyph: "⇧",
                name: L10n.string("mobile.toolbar.editor.modifier.shift", defaultValue: "Shift")
            ),
            ToolbarEditorModifierOption(
                modifier: .control,
                glyph: "⌃",
                name: L10n.string("mobile.toolbar.editor.modifier.control", defaultValue: "Control")
            ),
            ToolbarEditorModifierOption(
                modifier: .alternate,
                glyph: "⌥",
                name: L10n.string("mobile.toolbar.editor.modifier.option", defaultValue: "Option")
            ),
        ]
    }
}

extension TerminalSpecialKey {
    /// The special keys offered in the editor's combo picker, in a hand-ordered
    /// list (most common terminal keys first) rather than enum-declaration order.
    static var editorPickerOrder: [TerminalSpecialKey] {
        [
            .tab, .escape,
            .upArrow, .downArrow, .leftArrow, .rightArrow,
            .home, .end, .pageUp, .pageDown,
            .delete,
        ]
    }

    /// Localized display name for the editor's key picker.
    var editorDisplayName: String {
        switch self {
        case .tab: return L10n.string("mobile.toolbar.editor.key.tab", defaultValue: "Tab")
        case .escape: return L10n.string("mobile.toolbar.editor.key.escape", defaultValue: "Escape")
        case .upArrow: return L10n.string("mobile.toolbar.editor.key.upArrow", defaultValue: "Up Arrow")
        case .downArrow: return L10n.string("mobile.toolbar.editor.key.downArrow", defaultValue: "Down Arrow")
        case .leftArrow: return L10n.string("mobile.toolbar.editor.key.leftArrow", defaultValue: "Left Arrow")
        case .rightArrow: return L10n.string("mobile.toolbar.editor.key.rightArrow", defaultValue: "Right Arrow")
        case .home: return L10n.string("mobile.toolbar.editor.key.home", defaultValue: "Home")
        case .end: return L10n.string("mobile.toolbar.editor.key.end", defaultValue: "End")
        case .pageUp: return L10n.string("mobile.toolbar.editor.key.pageUp", defaultValue: "Page Up")
        case .pageDown: return L10n.string("mobile.toolbar.editor.key.pageDown", defaultValue: "Page Down")
        case .delete: return L10n.string("mobile.toolbar.editor.key.delete", defaultValue: "Forward Delete")
        }
    }
}
