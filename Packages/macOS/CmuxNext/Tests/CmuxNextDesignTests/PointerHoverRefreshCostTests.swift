import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// 2026-10-30, #27632's full Swift test run (job 123760619585): `swift test` hung for 1500 s with the
/// main thread in the display cycle's layout, and its sample showed `SidebarView.layout()` ->
/// `PointerHover.refresh(in:)` -> `TargetIndex.candidates(in:)` sorting. A sidebar layout pass
/// refreshes hover, and each refresh read, filed again and sorted every target of the window and
/// every target whose view had no window, so a layout pass cost every hover view the process kept.
/// A refresh now reads the hovering targets and the targets of the views under the pointer only.
@MainActor @Suite(.serialized, .closesItsWindows) struct PointerHoverRefreshCostTests {
    /// Counts the reads of its `window`, as the old index's filing did for every windowless target.
    private final class WindowReadCountingView: NSView {
        var windowReads = 0
        override var window: NSWindow? {
            windowReads += 1
            return super.window
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// 500 targets in the window (50 under each 20 pt stripe of a 100 pt column) and 2000 whose
    /// views are in no window: a refresh with the pointer over none asks none of them, and one with
    /// the pointer over a stripe asks only that stripe's 50.
    @Test func aRefreshReadsOnlyTheTargetsUnderThePointerAndTheHoveringOnes() throws {
        let window = Self.makeWindow()
        defer {
            PointerHover.debugPointers[ObjectIdentifier(window)] = nil
            window.close()
        }
        let content = try #require(window.contentView)
        var asked = 0
        var inWindow: [(view: NSView, hover: PointerHover)] = []
        for index in 0..<500 {
            let view = NSView(frame: NSRect(x: 0, y: CGFloat(index % 10) * 20, width: 100, height: 20))
            content.addSubview(view)
            let hover = PointerHover(view)
            hover.isHoverable = {
                asked += 1
                return true
            }
            inWindow.append((view, hover))
        }
        var detached: [(view: WindowReadCountingView, hover: PointerHover)] = []
        for _ in 0..<2000 {
            let view = WindowReadCountingView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            detached.append((view, PointerHover(view)))
        }
        let detachedReads = { detached.reduce(0) { $0 + $1.view.windowReads } }

        // The pointer over the window, right of the column: no target is under it.
        PointerHover.setDebugPointer(NSPoint(x: 300, y: 250), in: window)
        asked = 0
        for entry in detached { entry.view.windowReads = 0 }
        PointerHover.refresh(in: window)
        #expect(asked == 0, "a refresh with no target under the pointer asked \(asked) of the window's 500 targets")
        #expect(detachedReads() == 0, "a refresh read the window of \(detachedReads()) of 2000 targets in no window")

        // The pointer over the lowest stripe: its 50 targets hover, and only they are asked.
        asked = 0
        PointerHover.setDebugPointer(NSPoint(x: 50, y: 5), in: window)
        #expect(inWindow.filter { $0.hover.isHovering }.count == 50)
        #expect(asked == 50, "a refresh with 50 targets under the pointer asked \(asked)")
        #expect(detachedReads() == 0, "a refresh read the window of \(detachedReads()) of 2000 targets in no window")

        // The pointer leaves: the 50 that hovered clear, and nothing else is asked.
        asked = 0
        PointerHover.setDebugPointer(NSPoint(x: 300, y: 250), in: window)
        #expect(inWindow.allSatisfy { !$0.hover.isHovering })
        #expect(asked == 50, "the pointer leaving 50 hovering targets asked \(asked)")
        #expect(!detached.contains { $0.hover.isHovering })
    }

    /// A view made outside any window and added under a still pointer hovers at the next refresh
    /// (no enter arrives), and clears when it leaves; a hidden container's view never hovers.
    @Test func aViewAddedUnderAStillPointerHoversAtTheNextRefresh() throws {
        let window = Self.makeWindow()
        defer {
            PointerHover.debugPointers[ObjectIdentifier(window)] = nil
            window.close()
        }
        let content = try #require(window.contentView)
        let late = NSView(frame: NSRect(x: 200, y: 100, width: 50, height: 50))
        let hover = PointerHover(late)
        PointerHover.setDebugPointer(NSPoint(x: 225, y: 125), in: window)
        #expect(!hover.isHovering)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.addSubview(container)
        container.addSubview(late)
        PointerHover.refresh(in: window)
        #expect(hover.isHovering, "a view added under the pointer did not hover")

        container.isHidden = true
        PointerHover.refresh(in: window)
        #expect(!hover.isHovering, "a view in a hidden container still hovers")
        container.isHidden = false
        PointerHover.refresh(in: window)
        #expect(hover.isHovering)

        late.removeFromSuperview()
        PointerHover.refresh(in: window)
        #expect(!hover.isHovering, "a view that left the window still hovers")
    }

    /// A view moved from window A to window B under B's still pointer hovers at B's own next
    /// refresh (B's layout, an enter or exit, a key change): A's refresh no longer refreshes B.
    /// One that hovered in A and moved to B is still recomputed by A's refresh, against B's pointer.
    @Test func aViewMovedToAnotherWindowHoversAtThatWindowsOwnRefresh() throws {
        let a = Self.makeWindow(), b = Self.makeWindow()
        defer {
            for window in [a, b] {
                PointerHover.debugPointers[ObjectIdentifier(window)] = nil
                window.close()
            }
        }
        let contentA = try #require(a.contentView), contentB = try #require(b.contentView)
        let moving = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        contentA.addSubview(moving)
        let hover = PointerHover(moving)
        PointerHover.setDebugPointer(NSPoint(x: 300, y: 250), in: a)
        PointerHover.setDebugPointer(NSPoint(x: 25, y: 25), in: b)
        #expect(!hover.isHovering)

        contentB.addSubview(moving)
        PointerHover.refresh(in: b)
        #expect(hover.isHovering, "a view moved under B's pointer did not hover at B's refresh")

        // It hovers in B, and B's pointer leaves it: A's refresh recomputes it (it hovers), and it clears.
        PointerHover.debugPointers[ObjectIdentifier(b)] = PointerHover.DebugPointer(point: NSPoint(x: 300, y: 250), mouse: NSEvent.mouseLocation)
        PointerHover.refresh(in: a)
        #expect(!hover.isHovering, "a hovering view in another window was not recomputed")
    }
}
