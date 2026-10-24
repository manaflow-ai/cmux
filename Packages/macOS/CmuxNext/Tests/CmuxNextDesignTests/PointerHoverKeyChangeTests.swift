import AppKit
@testable import CmuxNextDesign
import Testing

/// A key-window change files again only the hover targets whose owners do not forward their window
/// moves (`PointerHover.ownerDidMoveToWindow()`), then refreshes the window that changed. It filed
/// every target of the app again (`placeAll`): O(all targets) twice per Cmd-Tab, with thousands
/// of targets in a STRESS session (perf-lead row 8).
@MainActor
@Suite(.serialized)
struct PointerHoverKeyChangeTests {
    /// A view that forwards its window moves, as every owner outside the sidebar does.
    private final class ForwardingView: NSView {
        var hover: PointerHover?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hover?.ownerDidMoveToWindow()
        }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func forwarding(in window: NSWindow, count: Int) -> [PointerHover] {
        (0..<count).map { index in
            let view = ForwardingView(frame: NSRect(x: 0, y: CGFloat(index), width: 100, height: 1))
            let hover = PointerHover(view)
            view.hover = hover
            window.contentView?.addSubview(view)
            return hover
        }
    }

    private func silent(in window: NSWindow, count: Int) -> [PointerHover] {
        (0..<count).map { index in
            let view = NSView(frame: NSRect(x: 0, y: CGFloat(index), width: 100, height: 1))
            window.contentView?.addSubview(view)
            return PointerHover(view)
        }
    }

    @Test func aKeyChangeFilesTheChangedWindowAndTheNonForwardingTargetsOnly() {
        let front = window(), back = window()
        defer {
            front.close()
            back.close()
        }
        let frontTargets = forwarding(in: front, count: 5)
        let backForwarding = forwarding(in: back, count: 5)
        let backSilent = silent(in: back, count: 2)
        let before = (front: frontTargets.map(\.placements), forwarding: backForwarding.map(\.placements),
                      silent: backSilent.map(\.placements))

        PointerHover.keyChanged(front)

        #expect(zip(frontTargets, before.front).allSatisfy { $0.placements > $1 }, "the changed window's targets refresh")
        #expect(zip(backForwarding, before.forwarding).allSatisfy { $0.placements == $1 },
                "a forwarding owner's target in another window is not filed again")
        #expect(zip(backSilent, before.silent).allSatisfy { $0.placements > $1 },
                "a non-forwarding owner's target is filed again (it may have moved windows)")
    }

    /// A non-forwarding owner's view that moved straight to another window is found there at the
    /// next key change, as before.
    @Test func aSilentViewMovedToAnotherWindowIsFiledThereAtAKeyChange() throws {
        let first = window(), second = window()
        defer {
            first.close()
            second.close()
        }
        let hover = try #require(silent(in: first, count: 1).first)
        let view = try #require(first.contentView?.subviews.last)
        second.contentView?.addSubview(view)
        let placed = hover.placements
        PointerHover.keyChanged(second)
        #expect(hover.placements > placed)
    }
}
