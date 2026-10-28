import AppKit
@testable import CmuxNextInput
import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// The input tap names the time of the last input event it dispatched in the crash-key page's `last_input_uptime`;
/// a tracking-area edge is no input of its own and names nothing.
@MainActor @Suite(.serialized)
struct InputEventTapCrashKeyTests {
    @Test func eachDispatchedEventNamesItsTime() throws {
        _ = NSApplication.shared
        let tap = InputEventTap(), keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        tap.crashKeys = keys
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 41.25,
                                                windowNumber: 0, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        tap.deliverObserve(key)
        #expect(page.value(.lastInputUptime) == 41_250_000_000)
        let edge = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 50,
                                                       windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        tap.deliverObserve(edge)
        #expect(page.value(.lastInputUptime) == 41_250_000_000, "a tracking-area edge named the last input")
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 60,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tap.deliverObserve(click)
        #expect(page.value(.lastInputUptime) == 60_000_000_000)
    }
}
