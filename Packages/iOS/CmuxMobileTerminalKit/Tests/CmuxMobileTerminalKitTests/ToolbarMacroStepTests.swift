import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("ToolbarMacroStep")
struct ToolbarMacroStepTests {
    @Test("text step normalizes newlines and treats empty as no output")
    func textStep() {
        #expect(ToolbarMacroStep.text("hi\n").output == Data("hi\r".utf8))
        #expect(ToolbarMacroStep.text("").output == nil)
    }

    @Test("key-combo step encodes through TerminalKeyEncoder, unsupported is nil")
    func keyComboStep() {
        #expect(ToolbarMacroStep.keyCombo(modifiers: [.shift], key: .tab).output == Data([0x1B, 0x5B, 0x5A]))
        #expect(ToolbarMacroStep.keyCombo(modifiers: [.control], key: .upArrow).output == nil)
    }
}
