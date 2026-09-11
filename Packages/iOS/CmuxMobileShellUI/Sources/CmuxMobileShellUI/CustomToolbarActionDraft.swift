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
    /// Maximum number of steps a key-sequence macro can contain.
    ///
    /// Validation runs during live editing, so the editor keeps the macro length
    /// bounded instead of scanning an arbitrary number of steps on every update.
    static let maximumKeySequenceStepCount = 50

    /// The button label.
    var title: String
    /// The kind of action being composed.
    var mode: CustomToolbarActionDraftMode
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
        mode: CustomToolbarActionDraftMode = .text,
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
            return !steps.isEmpty
                && steps.count <= Self.maximumKeySequenceStepCount
                && steps.allSatisfy { $0.output != nil }
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
