import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The one window-occlusion rule (``WindowDrawPolicy``): an occluded window
/// pauses drawing (energy saving), a visible window draws whether or not it
/// is key, and automation launches draw occluded windows (GUI proofs on a
/// host where the tagged app is never in front).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowDrawPolicyTests {
    private static func inputs(visible: Bool, hidden: Bool = false, suspended: Bool = false, forced: Bool = false,
                               override: Bool = false) -> SurfaceDrawInputs {
        SurfaceDrawInputs(inWindow: true, windowVisible: visible, hidden: hidden, suspended: suspended, forced: forced,
                          drawWhenOccluded: override)
    }

    /// A window that is never put on screen.
    static func offscreenWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func anOccludedWindowPausesForOcclusionAndAVisibleOneDraws() {
        #expect(Self.inputs(visible: false).pause == .windowOccluded)
        // Not key, not active: only on-screen visibility counts.
        #expect(Self.inputs(visible: true).draws)
        #expect(SurfaceDrawInputs(inWindow: false, windowVisible: false, hidden: false, suspended: false).pause == .notInWindow)
    }

    @Test func hiddenAndSuspendedSurfacesStayPausedEvenWhenOccludedWindowsDraw() {
        #expect(Self.inputs(visible: false, hidden: true, override: true).pause == .hidden)
        #expect(Self.inputs(visible: true, suspended: true, override: true).pause == .suspended)
        #expect(Self.inputs(visible: false, suspended: true, forced: true).draws, "a live mirror needs pixels")
    }

    @Test func drawWhenOccludedMakesAnOccludedWindowDraw() {
        #expect(Self.inputs(visible: false, override: true).draws)
    }

    @Test func onlyAutomationLaunchesDrawOccludedWindows() {
        #expect(WindowDrawPolicy.isAutomationLaunch(["CMUX_NEXT_NO_ACTIVATE": "1"]))
        #expect(WindowDrawPolicy.isAutomationLaunch(["CMUX_NEXT_SOCKET_MODE": "automation"]))
        #expect(!WindowDrawPolicy.isAutomationLaunch([:]), "a user launch keeps the energy saving")
        #expect(!WindowDrawPolicy.isAutomationLaunch(["CMUX_NEXT_NO_ACTIVATE": "0"]))
    }

    @Test func anAutomationLaunchMakesAnOccludedWindowDrawable() {
        let window = Self.offscreenWindow()
        let (saved, savedOnScreen) = (WindowDrawPolicy.drawsWhenOccluded, WindowDrawPolicy.onScreen)
        defer { (WindowDrawPolicy.drawsWhenOccluded, WindowDrawPolicy.onScreen) = (saved, savedOnScreen) }
        WindowDrawPolicy.onScreen = { _ in false }

        WindowDrawPolicy.drawsWhenOccluded = false
        #expect(!WindowDrawPolicy.isDrawable(window))
        WindowDrawPolicy.drawsWhenOccluded = true
        #expect(WindowDrawPolicy.isDrawable(window))
        #expect(!WindowDrawPolicy.isDrawable(nil))
    }
}
