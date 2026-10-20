import AppKit
import Carbon.HIToolbox
import Testing
import CmuxTerminalCore
import GhosttyKit

@Suite struct GhosttyInputActionFlagsChangedTests {
    @Test func leftShiftPressReturnsPress() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func leftShiftReleaseReturnsRelease() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: 0
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func leftShiftWithoutLeftSideDeviceMaskReturnsReleaseWhenRightShiftHeld() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightShiftRequiresRightSideDeviceMaskForPress() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func rightShiftWithoutRightSideDeviceMaskReturnsRelease() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightShiftWithoutRightSideDeviceMaskReturnsReleaseWhenLeftShiftHeld() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightControlRequiresRightSideDeviceMaskForPress() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3E,
                modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICERCTLKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func rightControlWithoutRightSideDeviceMaskReturnsRelease() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3E,
                modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightOptionRequiresRightSideDeviceMaskForPress() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3D,
                modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func rightOptionWithoutRightSideDeviceMaskReturnsRelease() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x3D,
                modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightCommandRequiresRightSideDeviceMaskForPress() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x36,
                modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func capsLockUsesLogicalModifierState() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x39,
                modifierFlagsRawValue: NSEvent.ModifierFlags.capsLock.rawValue
            ) == GHOSTTY_ACTION_PRESS
        )
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x39,
                modifierFlagsRawValue: 0
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func nonModifierKeyReturnsNil() {
        #expect(
            ghostty_input_action_e.modifierActionForFlagsChanged(
                keyCode: 0x00,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue
            ) == nil
        )
    }
}
