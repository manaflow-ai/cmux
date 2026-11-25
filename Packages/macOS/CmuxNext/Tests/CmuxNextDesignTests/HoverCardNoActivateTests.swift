import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing
import CmuxNextDesignTokens

/// A capture slot runs the app with `CMUX_NEXT_NO_ACTIVATE`, never frontmost, under other runs'
/// windows (Safari, permission dialogs): the system's topmost window over the tab strip was
/// another app's, so tab hover cards never opened in captures (op-next-icons, #19748). A
/// no-activate run hit-tests against its own windows; one of ours on top still blocks the card.
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardNoActivateTests {
    private final class Source: HoverCardSource {
        let window: NSWindow
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
            guard window.frame.contains(screenPoint) else { return nil }
            let target = HoverTarget(id: HoverTargetID("tab"), window: window.windowNumber, delay: .milliseconds(500))
            return HoverCardHit(target: target, anchor: window.frame)
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { window.frame }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    private func window(_ frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// The target hit with another app's window topmost at the pointer.
    private func hit(noActivate: Bool, coveredByOwnWindow: Bool) -> HoverTargetID? {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = noActivate
        defer { WindowPlacement.noActivate = saved }
        let main = window(CGRect(x: 200, y: 200, width: 300, height: 100))
        defer { main.close() }
        let frame = main.frame
        // Our window on top, as data: a second real window's visibility and frame
        // come from the window server, and once read as not covering (fleet run).
        let cover = coveredByOwnWindow ? (number: main.windowNumber + 1_000, frame: frame.insetBy(dx: -20, dy: -20)) : nil
        let source = Source(window: main)
        let coordinator = HoverCardCoordinator()
        coordinator.register(source)
        defer { coordinator.unregister(source) }
        coordinator.pointerLocation = { CGPoint(x: frame.midX, y: frame.midY) }
        coordinator.appIsActive = { true }
        coordinator.windowNumberAt = { _ in 999_999 }
        coordinator.ownWindows = { [cover, (number: main.windowNumber, frame: frame)].compactMap(\.self) }
        coordinator.pointerMoved()
        return coordinator.machine.lastHit?.id
    }

    @Test func aNoActivateRunFindsItsTabUnderAnotherAppsWindow() {
        #expect(hit(noActivate: true, coveredByOwnWindow: false) == HoverTargetID("tab"))
    }

    @Test func itsOwnWindowOnTopStillBlocksTheCard() {
        #expect(hit(noActivate: true, coveredByOwnWindow: true) == nil)
    }

    @Test func anActiveRunStillHonorsTheWindowOnTop() {
        #expect(hit(noActivate: false, coveredByOwnWindow: false) == nil)
    }
}
