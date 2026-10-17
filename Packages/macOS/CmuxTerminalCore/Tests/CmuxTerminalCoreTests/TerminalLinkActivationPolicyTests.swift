import CmuxTerminalCore
import Testing

@Suite struct TerminalLinkActivationPolicyTests {
    private let commandModifierRawValue: UInt = 0x0010_0000
    private let capsLockModifierRawValue: UInt = 0x0001_0000

    @Test func plainClickDoesNotReserveMouseReporting() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: 0,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
    }

    @Test func commandClickReservesMouseReporting() {
        #expect(TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
    }

    @Test func commandClickOutsideBoundsDoesNotReserveMouseReporting() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: false
        ))
    }

    @Test func extraModifiersRemainTerminalInput() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue | 0x0002_0000,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue | 0x0008_0000,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue | capsLockModifierRawValue | 0x0002_0000,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
    }

    @Test func commandClickWithCapsLockReservesMouseReporting() {
        #expect(TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: commandModifierRawValue | capsLockModifierRawValue,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
    }

    @Test func capsLockAloneDoesNotReserveMouseReporting() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: capsLockModifierRawValue,
            commandModifierRawValue: commandModifierRawValue,
            capsLockModifierRawValue: capsLockModifierRawValue,
            isInsideBounds: true
        ))
    }
}
