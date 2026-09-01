import CmuxTerminalCore
import Testing

@Suite("Terminal delete equivalent routing")
struct TerminalDeleteEquivalentRoutingPolicyTests {
    @Test(arguments: [51, 117] as [UInt16])
    func acceptsCommandDelete(keyCode: UInt16) {
        #expect(terminalDeleteEquivalentShouldDispatch(
            keyCode: keyCode,
            firstResponderIsTerminal: true,
            modifiers: [.command, .numericPad, .function]
        ))
    }

    @Test
    func rejectsForeignResponderMarkedTextAndOtherModifiers() {
        #expect(!terminalDeleteEquivalentShouldDispatch(
            keyCode: 51,
            firstResponderIsTerminal: false,
            modifiers: [.command]
        ))
        #expect(!terminalDeleteEquivalentShouldDispatch(
            keyCode: 51,
            firstResponderIsTerminal: true,
            firstResponderHasMarkedText: true,
            modifiers: [.command]
        ))
        #expect(!terminalDeleteEquivalentShouldDispatch(
            keyCode: 51,
            firstResponderIsTerminal: true,
            modifiers: [.command, .shift]
        ))
        #expect(!terminalDeleteEquivalentShouldDispatch(
            keyCode: 51,
            firstResponderIsTerminal: true,
            modifiers: [.command, .control]
        ))
        #expect(!terminalDeleteEquivalentShouldDispatch(
            keyCode: 51,
            firstResponderIsTerminal: true,
            modifiers: [.command],
            optionModifier: true
        ))
        #expect(!terminalDeleteEquivalentShouldDispatch(
            keyCode: 36,
            firstResponderIsTerminal: true,
            modifiers: [.command]
        ))
    }
}
