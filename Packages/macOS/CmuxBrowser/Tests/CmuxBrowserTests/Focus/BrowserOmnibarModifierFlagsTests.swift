import AppKit
import Testing
@testable import CmuxBrowser

@Suite("BrowserOmnibarModifierFlags")
struct BrowserOmnibarModifierFlagsTests {
    @Test func controlNavigationDeltaMapsNAndP() {
        let control: NSEvent.ModifierFlags = [.control]
        #expect(control.browserOmnibarSelectionDeltaForControlNavigation(hasFocusedAddressBar: true, chars: "n") == 1)
        #expect(control.browserOmnibarSelectionDeltaForControlNavigation(hasFocusedAddressBar: true, chars: "p") == -1)
        #expect(control.browserOmnibarSelectionDeltaForControlNavigation(hasFocusedAddressBar: true, chars: "x") == nil)
    }

    @Test func controlNavigationDeltaRequiresFocusAndControlOnly() {
        let control: NSEvent.ModifierFlags = [.control]
        #expect(control.browserOmnibarSelectionDeltaForControlNavigation(hasFocusedAddressBar: false, chars: "n") == nil)
        let controlShift: NSEvent.ModifierFlags = [.control, .shift]
        #expect(controlShift.browserOmnibarSelectionDeltaForControlNavigation(hasFocusedAddressBar: true, chars: "n") == nil)
    }

    @Test func controlNavigationIgnoresNumericPadAndCapsLock() {
        let noisy: NSEvent.ModifierFlags = [.control, .numericPad, .capsLock, .function]
        #expect(noisy.browserOmnibarSelectionDeltaForControlNavigation(hasFocusedAddressBar: true, chars: "n") == 1)
    }

    @Test func arrowNavigationDeltaMapsDownAndUp() {
        let none: NSEvent.ModifierFlags = []
        #expect(none.browserOmnibarSelectionDeltaForArrowNavigation(hasFocusedAddressBar: true, keyCode: 125) == 1)
        #expect(none.browserOmnibarSelectionDeltaForArrowNavigation(hasFocusedAddressBar: true, keyCode: 126) == -1)
        #expect(none.browserOmnibarSelectionDeltaForArrowNavigation(hasFocusedAddressBar: true, keyCode: 123) == nil)
    }

    @Test func arrowNavigationRequiresNoModifiers() {
        let shift: NSEvent.ModifierFlags = [.shift]
        #expect(shift.browserOmnibarSelectionDeltaForArrowNavigation(hasFocusedAddressBar: true, keyCode: 125) == nil)
        let none: NSEvent.ModifierFlags = []
        #expect(none.browserOmnibarSelectionDeltaForArrowNavigation(hasFocusedAddressBar: false, keyCode: 125) == nil)
    }

    @Test func markedTextBypassRequiresFocusMarkedTextAndNoCommand() {
        let none: NSEvent.ModifierFlags = []
        #expect(none.browserOmnibarShouldBypassShortcutRoutingForMarkedText(hasFocusedAddressBar: true, firstResponderHasMarkedText: true))
        #expect(!none.browserOmnibarShouldBypassShortcutRoutingForMarkedText(hasFocusedAddressBar: false, firstResponderHasMarkedText: true))
        #expect(!none.browserOmnibarShouldBypassShortcutRoutingForMarkedText(hasFocusedAddressBar: true, firstResponderHasMarkedText: false))
        let command: NSEvent.ModifierFlags = [.command]
        #expect(!command.browserOmnibarShouldBypassShortcutRoutingForMarkedText(hasFocusedAddressBar: true, firstResponderHasMarkedText: true))
    }

    @Test func continueControlNavigationRepeatOnlyForControlAlone() {
        let control: NSEvent.ModifierFlags = [.control]
        #expect(control.browserOmnibarShouldContinueControlNavigationRepeat)
        let controlOption: NSEvent.ModifierFlags = [.control, .option]
        #expect(!controlOption.browserOmnibarShouldContinueControlNavigationRepeat)
        let none: NSEvent.ModifierFlags = []
        #expect(!none.browserOmnibarShouldContinueControlNavigationRepeat)
    }

    @Test func submitOnReturnForPlainAndShift() {
        let none: NSEvent.ModifierFlags = []
        #expect(none.browserOmnibarShouldSubmitOnReturn)
        let shift: NSEvent.ModifierFlags = [.shift]
        #expect(shift.browserOmnibarShouldSubmitOnReturn)
        let command: NSEvent.ModifierFlags = [.command]
        #expect(!command.browserOmnibarShouldSubmitOnReturn)
    }
}
