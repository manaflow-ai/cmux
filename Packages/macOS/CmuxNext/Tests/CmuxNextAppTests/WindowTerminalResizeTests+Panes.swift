import AppKit
// Only the grid size: CmuxNextDaemon has its own PaneID (the daemon's handles).
import struct CmuxNextDaemon.CellSize
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Pane resizes with real terminals (Lawrence 2026-10-27: "we need resize tests, for both windows,
/// and panes too"): divider drags with the mouse, a close, a zoom and an unzoom, on the rig of
/// ``WindowTerminalResizeTests``.
extension WindowTerminalResizeTests.Rig {
    /// Drags divider `split` by `step` points per frame for `count` frames with the mouse
    /// (`DividerHandleView`'s mouse-down, -dragged and -up, as a person does), one layout and one
    /// coordinator frame per drag event. Every frame, each pane of `beside` gets a new grid and its
    /// PTY has it (the drag is real time: no hold until the release).
    func dragDivider(_ split: SplitID, on screen: ScreenID, step: CGVector, count: Int, beside: [PaneID]) async throws {
        let handle = try #require(root.screenViews[screen]?.dividerViews[.split(split)], "no handle for divider \(split)")
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        handle.mouseDown(with: mouse(.leftMouseDown, start))
        var previous: [PaneID: CellSize] = [:]
        for pane in beside { previous[pane] = fitted(pane) }
        var point = start
        for frame in 1...count {
            point = CGPoint(x: start.x + step.dx * CGFloat(frame), y: start.y + step.dy * CGFloat(frame))
            handle.mouseDragged(with: mouse(.leftMouseDragged, point))
            _ = root.advanceFrame(WindowTerminalResizeTests.dt)
            root.layoutSubtreeIfNeeded()
            await deliver()
            for pane in beside {
                let now = fitted(pane)
                #expect(now != previous[pane], "divider \(split) frame \(frame): \(pane)'s terminal kept \(String(describing: now))")
                #expect(terminals[pane]?.pty.applied.last == now,
                        "divider \(split) frame \(frame): \(pane)'s PTY has \(String(describing: terminals[pane]?.pty.applied.last)), its view fits \(String(describing: now))")
                previous[pane] = now
            }
        }
        // A still pointer at the release: no fling.
        eventTime += 0.5
        handle.mouseUp(with: mouse(.leftMouseUp, point))
    }

    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        eventTime += WindowTerminalResizeTests.dt
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: eventTime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: 1)!
    }
}

extension WindowTerminalResizeTests {
    /// Divider drags with the mouse, real time: the outer divider of p1 | (p2 / p3) moves 8 frames and
    /// every pane's terminal gets a grid each frame; then the nested divider between p2 and p3 moves 6
    /// frames and both stacked terminals get one each frame (p1's does not change). After the release
    /// every terminal fits its pane and its prompt is at the bottom (the growing side of each drag is
    /// the dogfood bug's grow).
    @Test func dividerDragsResizeThePaneTerminalsBesideThemEveryFrame() async throws {
        _ = NSApplication.shared
        let rig = try await Self.filledRig()
        defer { rig.close() }
        try await rig.dragDivider("r", on: "s", step: CGVector(dx: -16, dy: 0), count: 8, beside: Self.panes)
        try await rig.expectSettled(Self.panes, "outer divider dragged")
        let side = rig.fitted("p1")
        try await rig.dragDivider("d", on: "s", step: CGVector(dx: 0, dy: 26), count: 6, beside: ["p2", "p3"])
        #expect(rig.fitted("p1") == side, "a nested divider drag resized the side pane")
        try await rig.expectSettled(Self.panes, "nested divider dragged")
    }

    /// A pane closes (p3: p2 takes its rows), a pane zooms (p2 takes the window) and unzooms (every
    /// pane back to its size): after each, every visible pane's terminal fits its pane, its PTY holds
    /// that grid, and its prompt is at the bottom.
    @Test func aCloseAZoomAndAnUnzoomGiveEveryPaneTerminalItsFrame() async throws {
        _ = NSApplication.shared
        let rig = try await Self.filledRig()
        defer { rig.close() }
        let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        let stacked = try #require(rig.fitted("p2"))

        rig.model.apply(screens: [Self.screen("s", pair)])
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try await rig.expectSettled(["p1", "p2"], "p3 closed")
        let alone = try #require(rig.fitted("p2"))
        #expect(alone.rows > stacked.rows, "closing p3 did not give p2 its rows: \(stacked) -> \(alone)")

        rig.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p2")), zoomed: true)])
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try await rig.expectSettled(["p2"], "p2 zoomed")
        let zoomed = try #require(rig.fitted("p2"))
        #expect(zoomed.cols > alone.cols, "the zoom did not give p2 the window: \(alone) -> \(zoomed)")

        rig.model.apply(screens: [Self.screen("s", pair)])
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try await rig.expectSettled(["p1", "p2"], "p2 unzoomed")
        #expect(rig.fitted("p2") == alone, "the unzoom did not give p2 its size back")
    }
}
