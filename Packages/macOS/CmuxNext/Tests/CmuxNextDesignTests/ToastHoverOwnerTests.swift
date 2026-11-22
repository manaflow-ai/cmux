import AppKit
@testable import CmuxNextDesign
import Testing

/// cx-3wu5: a toast's hover follows the pointer and the toast's slot now. A
/// new toast pushes the hovered one up a slot under a still pointer; no exit
/// arrives. The toast that moved away must lose its hover and restart its
/// timer (it never ended before), and the toast now under the pointer holds.
@MainActor @Suite(.serialized)
struct ToastHoverOwnerTests {
    /// Places toasts in the window's content view, slot 0 lowest, so they
    /// have real frames under the pointer.
    final class FramedHost: CmuxToastHosting {
        static let height: CGFloat = 40
        func frame(slot: Int) -> NSRect { NSRect(x: 20, y: 20 + CGFloat(slot) * (Self.height + 8), width: 300, height: Self.height) }

        func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, windowGone: @escaping () -> Void) {
            toast.translatesAutoresizingMaskIntoConstraints = true
            toast.frame = frame(slot: slot)
            window.contentView?.addSubview(toast)
        }

        func move(_ toast: CmuxToastView, to slot: Int) { toast.frame = frame(slot: slot) }
        func hide(_ toast: CmuxToastView) { toast.removeFromSuperview() }
    }

    @Test func aHoveredToastPushedAwayUnderAStillPointerEndsOnTime() async throws {
        let clock = ManualClock()
        let host = FramedHost()
        let center = CmuxToastCenter(clock: clock, host: host)
        let window = CmuxToastTests.window()
        defer { PointerHover.clearDebugPointer(in: window); window.close() }
        var reasons: [String: CmuxToastDismissReason] = [:]
        let first = center.show(CmuxToast(id: "first", message: "First", duration: .seconds(5)), in: window)
        first.onDismiss = { reasons["first"] = $0 }
        let view = try #require(window.contentView?.subviews.compactMap { $0 as? CmuxToastView }.first { $0.toast.id == "first" })

        // The pointer rests on the first toast (slot 0); the enter reaches the tracking area's owner.
        let windowPoint = NSPoint(x: view.frame.midX, y: view.frame.midY)
        PointerHover.setDebugPointer(windowPoint, in: window)
        view.updateTrackingAreas()
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil))
        for area in view.trackingAreas {
            if let hover = area.owner as? PointerHover { hover.mouseEntered(with: event) } else if let owner = area.owner as? NSResponder {
                owner.mouseEntered(with: event)
            }
        }

        // A second toast arrives at slot 0: the first moves up, away from the pointer.
        let second = center.show(CmuxToast(id: "second", message: "Second", duration: .seconds(5)), in: window)
        second.onDismiss = { reasons["second"] = $0 }
        #expect(!view.frame.contains(windowPoint), "the first toast moved up a slot")

        // Bounded: a toast whose timer stays cancelled never ends.
        for _ in 0..<200 where reasons["first"] == nil {
            clock.advance(by: .seconds(1))
            for _ in 0..<5 { await Task.yield() }
        }
        #expect(reasons["first"] == .timeout, "the toast that moved away ends after its time")
        #expect(reasons["second"] == nil, "the toast under the pointer holds")
    }
}
