import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE P0 7 cause M (px-col-drag-2-s1r, cmux21 120 Hz 1x, build fd7a1664): the frame that holds a divider's press and
/// first move lays out 101 views in 18.3 ms and misses two refreshes; each frame of the drag after it lays out 18-27.
/// The Chrome model: a motion frame lays out only the boxes whose size changes (CLAUDE.md: a layout per animation frame
/// that changes nothing is a bug), and a press that moves nothing lays nothing out.
///
/// The rule, counted with `LayoutPassGuard` (`-[NSView layout]` calls per view class), as `KeyResizeLayoutsPerFrameTests`
/// counts a key resize: the press's turn lays nothing out, and in each frame of the drag a view class is laid out at most
/// as many times as views of that class changed size in that frame.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct DividerDragLayoutsPerFrameTests {
    typealias Ground = PaneGroundCoversPaneTests
    typealias Counts = KeyResizeLayoutsPerFrameTests

    static func event(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// p1 | p2 with a terminal in each: the split's divider pressed, then moved 6 pt right in each of 20 frames.
    @Test func aDividerDragLaysOutOnlyTheViewsWhoseSizeChanges() throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p1")
        defer { rig.close() }
        let root = try #require(rig.window.contentView)
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()
        let screen = try rig.screen
        let handle = try #require(screen.dividerViews[.split("x")], "no split handle in \(screen.dividerViews.keys)")
        var point = screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)

        var start = Counts.calls()
        handle.mouseDown(with: try Self.event(.leftMouseDown, point, in: rig.window))
        let pressTurn = Counts.since(start)
        var extra: [String] = pressTurn.isEmpty ? [] : ["press turn: \(Counts.text(pressTurn))"]
        var perFrame: [String] = []
        for frame in 1...24 {
            let before = Counts.sizes(under: root)
            start = Counts.calls()
            if frame <= 20 {
                point.x += 6
                handle.mouseDragged(with: try Self.event(.leftMouseDragged, point, in: rig.window))
            }
            let began = ContinuousClock.now
            _ = rig.frame()
            let took = ContinuousClock.now - began
            let laid = Counts.since(start)
            var resized: [String: Int] = [:]
            for (id, entry) in Counts.sizes(under: root) where before[id]?.size != entry.size { resized[entry.viewClass, default: 0] += 1 }
            if frame <= 3 { perFrame.append("frame \(frame) (\(took)): laid out [\(Counts.text(laid))], resized [\(Counts.text(resized))]") }
            for (viewClass, count) in laid where count > resized[viewClass, default: 0] {
                extra.append("frame \(frame): \(viewClass) laid out \(count)x, \(resized[viewClass, default: 0]) resized")
            }
        }
        handle.mouseUp(with: try Self.event(.leftMouseUp, point, in: rig.window))
        while rig.frame() {}
        #expect(extra.isEmpty, "\(extra.count) layouts of views whose size did not change: \(extra.prefix(16)). \(perFrame)")
    }
}
