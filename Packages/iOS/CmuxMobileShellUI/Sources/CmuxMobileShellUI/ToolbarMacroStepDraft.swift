#if os(iOS)
import CmuxMobileTerminalKit
import Foundation

struct ToolbarMacroStepDraft: Equatable, Identifiable {
    let id: UUID
    var kind: ToolbarMacroStepKind
    var text: String
    var runAfterTyping: Bool
    var modifiers: TerminalKeyModifier
    var key: TerminalSpecialKey

    init(
        id: UUID = UUID(),
        kind: ToolbarMacroStepKind,
        text: String = "",
        runAfterTyping: Bool = false,
        modifiers: TerminalKeyModifier = [.shift],
        key: TerminalSpecialKey = .tab
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.runAfterTyping = runAfterTyping
        self.modifiers = modifiers
        self.key = key
    }

    init(step: ToolbarActionMacroStep) {
        switch step {
        case let .text(stored):
            let seed = Self.textSeed(from: stored)
            self.init(kind: .text, text: seed.text, runAfterTyping: seed.runAfterTyping)
        case let .keyCombo(modifiers, key):
            self.init(kind: .keyCombo, modifiers: modifiers, key: key)
        }
    }

    static func textStep() -> ToolbarMacroStepDraft {
        ToolbarMacroStepDraft(kind: .text)
    }

    static func keyComboStep() -> ToolbarMacroStepDraft {
        ToolbarMacroStepDraft(kind: .keyCombo)
    }

    var macroStep: ToolbarActionMacroStep? {
        switch kind {
        case .text:
            guard !text.isEmpty || runAfterTyping else { return nil }
            return .text(runAfterTyping ? text + "\n" : text)
        case .keyCombo:
            let step = ToolbarActionMacroStep.keyCombo(modifiers: modifiers, key: key)
            guard step.output != nil else { return nil }
            return step
        }
    }

    var hasSupportedOutput: Bool {
        macroStep?.output != nil
    }

    static func textSeed(from stored: String) -> (text: String, runAfterTyping: Bool) {
        if stored.hasSuffix("\n") {
            return (String(stored.dropLast()), true)
        }
        return (stored, false)
    }
}
#endif
