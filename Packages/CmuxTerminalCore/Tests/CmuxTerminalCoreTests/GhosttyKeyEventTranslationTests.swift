import AppKit
import Carbon.HIToolbox
import Testing
import CmuxTerminalCore
import GhosttyKit

@Suite struct GhosttyKeyEventTranslationTests {
    @Test func leftShiftPressReturnsPress() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func leftShiftReleaseReturnsRelease() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: 0
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func leftShiftWithoutLeftSideDeviceMaskReturnsReleaseWhenRightShiftHeld() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightShiftRequiresRightSideDeviceMaskForPress() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func rightShiftWithoutRightSideDeviceMaskReturnsRelease() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightShiftWithoutRightSideDeviceMaskReturnsReleaseWhenLeftShiftHeld() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightControlRequiresRightSideDeviceMaskForPress() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3E,
                modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICERCTLKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func rightControlWithoutRightSideDeviceMaskReturnsRelease() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3E,
                modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightOptionRequiresRightSideDeviceMaskForPress() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3D,
                modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func rightOptionWithoutRightSideDeviceMaskReturnsRelease() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x3D,
                modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func rightCommandRequiresRightSideDeviceMaskForPress() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x36,
                modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK)
            ) == GHOSTTY_ACTION_PRESS
        )
    }

    @Test func capsLockUsesLogicalModifierState() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x39,
                modifierFlagsRawValue: NSEvent.ModifierFlags.capsLock.rawValue
            ) == GHOSTTY_ACTION_PRESS
        )
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x39,
                modifierFlagsRawValue: 0
            ) == GHOSTTY_ACTION_RELEASE
        )
    }

    @Test func nonModifierKeyReturnsNil() {
        #expect(
            GhosttyKeyEventTranslation.modifierActionForFlagsChanged(
                keyCode: 0x00,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue
            ) == nil
        )
    }
}
