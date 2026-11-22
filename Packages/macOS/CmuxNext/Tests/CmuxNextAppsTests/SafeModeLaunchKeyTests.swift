import AppKit
@testable import CmuxNextApps
import Testing

/// Safe mode's launch key (docs/cmux-next/extensions/safe-mode.md) is Shift alone: Option+Shift
/// is the launch that ignores customizations, and no key held changes nothing.
@MainActor @Suite struct SafeModeLaunchKeyTests {
    @Test func shiftAloneIsTheKey() {
        #expect(SafeModeLaunch.keyHeld(.shift))
        #expect(SafeModeLaunch.keyHeld([.shift, .capsLock]))
    }

    @Test func otherKeysAreNot() {
        #expect(!SafeModeLaunch.keyHeld([]))
        #expect(!SafeModeLaunch.keyHeld(.capsLock))
        #expect(!SafeModeLaunch.keyHeld([.shift, .option]))
        #expect(!SafeModeLaunch.keyHeld([.shift, .command]))
        #expect(!SafeModeLaunch.keyHeld(.option))
    }
}
