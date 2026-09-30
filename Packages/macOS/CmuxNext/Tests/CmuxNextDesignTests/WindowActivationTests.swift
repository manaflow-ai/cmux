import AppKit
@testable import CmuxNextDesign
import Testing

/// Under CMUX_NEXT_NO_ACTIVATE=1 no window becomes key and the app never
/// activates, whatever the intent: a relaunch must not take the focus from
/// the user's current app.
@MainActor
struct WindowActivationTests {
    @Test func noActivateNeverMakesAWindowKeyOrActivatesTheApp() {
        for intent in [WindowActivation.Intent.present, .raise, .focus] {
            for testScreen in [false, true] {
                let plan = WindowActivation.plan(intent, noActivate: true, testScreen: testScreen)
                #expect(plan.order != .makeKeyAndOrderFront, "\(intent), test screen \(testScreen)")
                #expect(!plan.activatesApp, "\(intent), test screen \(testScreen)")
            }
        }
        #expect(WindowActivation.plan(.present, noActivate: true, testScreen: false).order == .orderBack)
        #expect(WindowActivation.plan(.present, noActivate: true, testScreen: true).order == .orderFrontRegardless)
    }

    @Test func aNormalLaunchFocusesAndOnlyFocusActivates() {
        #expect(WindowActivation.plan(.present, noActivate: false, testScreen: false)
                == .init(order: .makeKeyAndOrderFront, activatesApp: false))
        #expect(WindowActivation.plan(.raise, noActivate: false, testScreen: false)
                == .init(order: .makeKeyAndOrderFront, activatesApp: false))
        #expect(WindowActivation.plan(.focus, noActivate: false, testScreen: false)
                == .init(order: .makeKeyAndOrderFront, activatesApp: true))
    }

    /// A window shown through the owner under no-activate is on screen and
    /// not key (the test process is never active either way).
    @Test func showUnderNoActivateOrdersInWithoutTheKeys() {
        let saved = (WindowPlacement.noActivate, WindowPlacement.testScreen)
        defer { (WindowPlacement.noActivate, WindowPlacement.testScreen) = saved }
        WindowPlacement.noActivate = true
        WindowPlacement.testScreen = nil
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 40, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        WindowActivation.show(window, .focus)
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(!NSApp.isActive)
    }
}
