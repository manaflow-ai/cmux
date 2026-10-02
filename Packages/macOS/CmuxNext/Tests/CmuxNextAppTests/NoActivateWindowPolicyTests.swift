import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// Agent screenshot launches (`CMUX_NEXT_NO_ACTIVATE=1` with
/// `CMUX_NEXT_TEST_WINDOW_SCREEN`): every window stays on the test screen
/// and the app never keeps the keyboard it did not get from the user.
/// Tagged build tdrag2: a window ended on the user's main display and the
/// app later held a key window, after agent `debug.mouse` drags.
@MainActor @Suite(.serialized) struct NoActivateWindowPolicyTests {
    // MARK: Agent input is not the user

    private func mouseDown() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The guard trusts input in the last second as the user choosing the
    /// app; a `debug.mouse` press must not count, or an activation right
    /// after an agent's drag keeps the keyboard.
    @Test func agentPostedInputIsNotUserInput() {
        let posted = mouseDown()
        SyntheticInput.register([posted])
        #expect(!SyntheticInput.isUserInput(posted))
        #expect(SyntheticInput.isUserInput(mouseDown()))
    }

    @Test func anActivationRightAfterAgentInputIsGivenBack() {
        let host = NoActivateKeyboardGuardTests.FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        let posted = mouseDown()
        SyntheticInput.register([posted])
        if SyntheticInput.isUserInput(posted) { guardian.userInput() }
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo == [501])
    }

    // MARK: Every window stays on the test screen

    @Test func aFrameOffTheScreenMovesInsideIt() {
        let visible = CGRect(x: 2560, y: -358, width: 1728, height: 1085)
        // A tear-off frame under a pointer on the main display.
        let contained = WindowPlacement.contain(CGRect(x: 224, y: 112, width: 1100, height: 720), in: visible)
        #expect(visible.contains(contained))
        #expect(contained.size == CGSize(width: 1100, height: 720))
        // A frame already inside stays put; a too-large one shrinks.
        let inside = CGRect(x: 2700, y: 0, width: 800, height: 600)
        #expect(WindowPlacement.contain(inside, in: visible) == inside)
        #expect(WindowPlacement.contain(CGRect(x: 0, y: 0, width: 4000, height: 3000), in: visible) == visible)
    }

    /// Every programmatic frame change of a shell window (tear-off,
    /// move-window, new window, restore) goes through `setFrame`.
    @Test func aShellWindowFrameSetOffTheTestScreenLandsOnIt() throws {
        let screens = NSScreen.screens
        try #require(!screens.isEmpty)
        let saved = WindowPlacement.testScreen
        WindowPlacement.testScreen = .last
        defer { WindowPlacement.testScreen = saved }
        let visible = try #require(screens.last).visibleFrame
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                                 defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // A frame on no screen at all (far away from every display).
        window.setFrame(CGRect(x: -40_000, y: -40_000, width: 600, height: 400), display: false)
        #expect(visible.contains(window.frame), "\(window.frame) not in \(visible)")
    }

    @Test func withoutATestScreenFramesAreLeftAlone() {
        let saved = WindowPlacement.testScreen
        WindowPlacement.testScreen = nil
        defer { WindowPlacement.testScreen = saved }
        let frame = CGRect(x: -40_000, y: -40_000, width: 600, height: 400)
        #expect(WindowPlacement.containedOnTestScreen(frame) == frame)
    }

    // MARK: The activation rule

    @Test func noActivateNeverMakesAWindowKeyOrActivates() {
        for intent in [WindowActivation.Intent.present, .raise, .focus] {
            for test in [true, false] {
                let plan = WindowActivation.plan(intent, noActivate: true, testScreen: test)
                #expect(plan.order != .makeKeyAndOrderFront, "\(intent) test=\(test)")
                #expect(!plan.activatesApp, "\(intent) test=\(test)")
            }
            #expect(WindowActivation.plan(intent, noActivate: true, testScreen: true).order == .orderFrontRegardless)
        }
    }
}
