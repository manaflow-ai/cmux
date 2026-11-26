import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The hover-card coordinator hears every window's move and resize, and for each one looked for that window among every
/// source's window (each tab cell, sidebar row and toolbar that shows cards) before it asked whether the move could
/// change a card. A divider drag moves windows no source lives in on every display frame (a Chromium page's window, a
/// divider's catcher panel), with the button held: 15 to 24 main-thread samples of a sampled drag (release-resize
/// bp-off-2 and bp-on-2, 2026-11-26). A move that cannot change a card (a button is down, or nothing hovered and the
/// pointer is outside the window) reads no source.
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardForeignWindowMoveTests {
    private final class Source: HoverCardSource {
        let window: NSWindow
        var reads = 0
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? {
            reads += 1
            return window
        }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    private struct Rig {
        let home: NSWindow
        let page: NSWindow
        let coordinator: HoverCardCoordinator
        let sources: [Source]
        var reads: Int { sources.reduce(0) { $0 + $1.reads } }
        func resetReads() { for source in sources { source.reads = 0 } }
        func close() {
            for source in sources { coordinator.unregister(source) }
            home.close()
            page.close()
        }
    }

    private func window(_ frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// 40 sources in `home`; `page` holds none (a page's window, a catcher panel).
    private func rig(pointer: @escaping () -> CGPoint, buttonDown: Bool) -> Rig {
        _ = NSApplication.shared
        let home = window(CGRect(x: 100, y: 100, width: 500, height: 400))
        let page = window(CGRect(x: 700, y: 100, width: 300, height: 300))
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { buttonDown }
        coordinator.pointerLocation = pointer
        let sources = (0..<40).map { _ in Source(window: home) }
        for source in sources { coordinator.register(source) }
        return Rig(home: home, page: page, coordinator: coordinator, sources: sources)
    }

    private func resize(_ window: NSWindow, steps: Int) {
        for step in 1...steps {
            window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: 300 + 3 * step, height: 300 + 2 * step)),
                            display: false)
        }
    }

    @Test func aWindowMovedWithTheButtonDownReadsNoSource() {
        let r = rig(pointer: { CGPoint(x: 800, y: 200) }, buttonDown: true)
        defer { r.close() }
        r.resetReads()
        resize(r.page, steps: 10)
        #expect(r.reads == 0, "\(r.reads) reads of a source's window in 10 moves of a window under a held button")
    }

    @Test func aWindowMovedAwayFromThePointerWithNothingHoveredReadsNoSource() {
        let r = rig(pointer: { CGPoint(x: 20, y: 20) }, buttonDown: false)
        defer { r.close() }
        #expect(r.coordinator.machine.phase == .idle && r.coordinator.machine.lastHit == nil, "fixture: something is hovered")
        r.resetReads()
        resize(r.page, steps: 10)
        #expect(r.reads == 0, "\(r.reads) reads of a source's window in 10 moves of a window the pointer is not over")
    }

    /// A source's own window moving under the pointer still looks for a target there.
    @Test func aSourceWindowMovedUnderThePointerStillHitTests() {
        let r = rig(pointer: { CGPoint(x: 200, y: 200) }, buttonDown: false)
        defer { r.close() }
        r.resetReads()
        r.home.setFrame(NSRect(x: 100, y: 100, width: 520, height: 400), display: false)
        #expect(r.reads > 0, "a move of the sources' window under the pointer looked for no target")
    }
}
