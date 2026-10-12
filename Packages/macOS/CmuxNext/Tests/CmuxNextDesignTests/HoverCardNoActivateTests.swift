import AppKit
@testable import CmuxNextDesign
import Testing

/// A capture slot runs the app with `CMUX_NEXT_NO_ACTIVATE` under the Cua Driver's full-screen
/// window, so the system's topmost window at the pointer is never ours and hover cards never
/// opened in captures (op-next-icons, #19748/#19754). A no-activate run hit-tests against its own
/// windows; one of ours on top still blocks the card.
@MainActor @Suite(.serialized) struct HoverCardNoActivateTests {
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

    private func hit(foreignOverlay: Bool, coveredByOwnWindow: Bool) -> HoverTargetID? {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = true
        defer { WindowPlacement.noActivate = saved }
        let frame = CGRect(x: 200, y: 200, width: 300, height: 100)
        let main = window(frame)
        let cover = coveredByOwnWindow ? window(frame.insetBy(dx: -20, dy: -20)) : nil
        defer { main.close(); cover?.close() }
        let source = Source(window: main)
        let coordinator = HoverCardCoordinator()
        coordinator.register(source)
        defer { coordinator.unregister(source) }
        coordinator.pointerLocation = { CGPoint(x: frame.midX, y: frame.midY) }
        if foreignOverlay { coordinator.windowNumberAt = { _ in 999_999 } }
        coordinator.pointerMoved()
        return coordinator.machine.lastHit?.id
    }

    @Test func aNoActivateRunFindsItsTargetUnderAForeignOverlay() {
        #expect(hit(foreignOverlay: true, coveredByOwnWindow: false) == HoverTargetID("tab"))
    }

    @Test func itsOwnWindowOnTopStillBlocksTheCard() {
        #expect(hit(foreignOverlay: true, coveredByOwnWindow: true) == nil)
    }
}
