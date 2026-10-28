import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import Testing

/// The popup's key-loss rule reads the press being dispatched from the click observer and the tap,
/// not AppKit's current event: a press on the toggle keeps it open, and once
/// another event was dispatched that press no longer counts (a later focus change is no press).
@MainActor @Suite(.serialized) struct NativePopupHostDispatchedPressTests {
    @Test func thePressInDispatchIsTheObservedOneUntilAnotherEventIsDispatched() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let host = NativePopupHost(panel: NativePopupPanel(identifier: "test.popup.press"), input: events.tap)
        let anchor = CGRect(x: window.frame.midX - 20, y: window.frame.midY, width: 40, height: 20)
        try #require(host.show(size: CGSize(width: 160, height: 100), anchor: anchor, in: window, entrance: false) != nil)
        defer { host.hide() }
        host.keepsOpen = { _ in true }
        #expect(host.dispatchedPress() == nil, "a press before any click")

        let press = try InputTapTestEvents.mouse(.leftMouseDown, in: window)
        events.dispatch(press)
        #expect(host.dispatchedPress() === press, "the toggle's press was not the one in dispatch")

        events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 0, in: window))
        #expect(host.dispatchedPress() == nil, "a press stayed current after a key was dispatched")
    }
}
