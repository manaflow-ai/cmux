@testable import CmuxNextActions
import Testing

/// User key modes (row key-modes, design/key-modes.md): an entry under `keyMode == 'name'` may bind a bare key,
/// as the daemon's reader (cmux-config `keybindings::bare`) allows; the mode owns bare keys in any focus but a text field.
@MainActor @Suite struct KeyModeBareKeysTests {
    @Test func aModeClauseAllowsBareKeys() throws {
        for text in ["keyMode == 'pane'", "keyMode", "keyMode == 'pane' && surfaceKind == 'markdown'"] {
            let when = try WhenClause.parse(text)
            #expect(when.allowsBareKeys, "\(text)")
            #expect(when.requiresKeyMode, "\(text)")
        }
    }

    @Test func otherModeClausesDoNot() throws {
        for text in ["keyMode != 'pane'", "keyMode == ''", "keyMode == 'pane' && terminalFocused", "keyMode == 'pane' || browserFocused"] {
            #expect(!(try WhenClause.parse(text)).allowsBareKeys, "\(text)")
        }
        #expect(!(try WhenClause.parse("terminalFocused")).requiresKeyMode)
    }

    @Test func aModeOwnsBareKeysOutsideTextFields() {
        var context = KeyContext()
        #expect(!context.ownsBareKeys)
        context[KeyContext.keyMode] = .string("pane")
        #expect(context.inKeyMode && context.ownsBareKeys)
        context[KeyContext.textInputFocus] = .bool(true)
        #expect(!context.ownsBareKeys, "a text field keeps typing")
        context = KeyContext([KeyContext.keyMode: .string("")])
        #expect(!context.inKeyMode)
    }
}
