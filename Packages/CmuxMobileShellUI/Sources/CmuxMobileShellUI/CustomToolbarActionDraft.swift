import CmuxMobileSupport
import CmuxMobileTerminalKit
import Foundation

/// Pure, UI-independent state behind ``CustomToolbarActionEditorView``.
///
/// Seeds the editor's fields from an action being edited and rebuilds the
/// resulting ``CustomToolbarAction`` on save, so the editor's seed → build →
/// validity behavior is testable without instantiating SwiftUI. The editor view
/// owns `@State` mirrors of these fields and constructs a draft on the fly to
/// drive its Save button and produce the saved action.
struct CustomToolbarActionDraft: Equatable {
    /// Which kind of action the editor is composing.
    enum Mode: Hashable, CaseIterable {
        /// A literal command/snippet, optionally Return-terminated.
        case text
        /// An ordered sequence of key combos and/or text snippets — a macro.
        case keySequence
    }

    /// The button label.
    var title: String
    /// The kind of action being composed.
    var mode: Mode
    /// Text-mode command body.
    var commandText: String
    /// Text-mode: append a Return so the command submits rather than only typing.
    var runAfterTyping: Bool
    /// Key-sequence-mode ordered steps.
    var steps: [ToolbarMacroStep]

    /// Creates a draft from explicit field values (used by the editor's live
    /// projection and by tests).
    init(
        title: String = "",
        mode: Mode = .text,
        commandText: String = "",
        runAfterTyping: Bool = true,
        steps: [ToolbarMacroStep] = []
    ) {
        self.title = title
        self.mode = mode
        self.commandText = commandText
        self.runAfterTyping = runAfterTyping
        self.steps = steps
    }

    /// Seeds a draft from an action being edited, or an empty draft (text mode,
    /// Return-terminated) when creating a new one.
    ///
    /// A `.keyCombo` action seeds the key-sequence editor with a single step so
    /// it round-trips through the same UI as a multi-step macro.
    init(action: CustomToolbarAction?) {
        guard let action else {
            self.init()
            return
        }
        switch action.payload {
        case let .text(stored):
            if stored.hasSuffix("\n") {
                self.init(
                    title: action.title,
                    mode: .text,
                    commandText: String(stored.dropLast()),
                    runAfterTyping: true
                )
            } else {
                self.init(title: action.title, mode: .text, commandText: stored, runAfterTyping: false)
            }
        case let .keyCombo(modifiers, key):
            self.init(
                title: action.title,
                mode: .keySequence,
                steps: [.keyCombo(modifiers: modifiers, key: key)]
            )
        case let .macro(steps):
            self.init(title: action.title, mode: .keySequence, steps: steps)
        }
    }

    /// The label with surrounding whitespace trimmed.
    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the draft can be saved into a working action.
    ///
    /// Requires a non-empty label, and for a key sequence at least one step where
    /// every step resolves to bytes — so a saved macro never carries a dead step
    /// (empty text or a key combo the encoder can't encode).
    var isValid: Bool {
        guard !trimmedTitle.isEmpty else { return false }
        switch mode {
        case .text:
            return !commandText.isEmpty
        case .keySequence:
            return !steps.isEmpty && steps.allSatisfy { $0.output != nil }
        }
    }

    /// Builds the action, preserving `id`, or `nil` when ``isValid`` is `false`.
    func build(id: UUID) -> CustomToolbarAction? {
        guard isValid else { return nil }
        let payload: ToolbarActionPayload
        switch mode {
        case .text:
            payload = .text(runAfterTyping ? commandText + "\n" : commandText)
        case .keySequence:
            payload = .macro(steps)
        }
        return CustomToolbarAction(id: id, title: trimmedTitle, symbolName: nil, payload: payload)
    }
}

/// A modifier the toolbar-action editor exposes as a toggle chip, carrying its
/// on-key glyph and a localized accessibility name.
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
