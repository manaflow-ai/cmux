import CmuxTerminalCore
import Testing

@Suite struct TerminalLinkActivationPolicyTests {
    private let commandModifierRawValue: UInt = 0x0010_0000

    @Test func plainClickDoesNotReserveMouseReporting() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: 0,
            commandModifierRawValue: commandModifierRawValue,
            isInsideBounds: true
        ))
    }

    @Test func commandClickReservesMouseReporting() {
        #expect(TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue,
            commandModifierRawValue: commandModifierRawValue,
            isInsideBounds: true
        ))
    }

    @Test func commandClickOutsideBoundsDoesNotReserveMouseReporting() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue,
            commandModifierRawValue: commandModifierRawValue,
            isInsideBounds: false
        ))
    }

    @Test func extraModifiersRemainTerminalInput() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue | 0x0002_0000,
            commandModifierRawValue: commandModifierRawValue,
            isInsideBounds: true
        ))
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue | 0x0008_0000,
            commandModifierRawValue: commandModifierRawValue,
            isInsideBounds: true
        ))
    }
}
