import AppKit
import CmuxNextInput
@testable import CmuxNextTabs
import CmuxNextWakeups
import Testing

/// Tab strip hover once per frame (feature `pointerFrameHover`) on p04-input-030's
/// `FrameInputCoalescer`, as Chromium delivers rAF-aligned moves (main_thread_event_queue.cc): the
/// first move of a frame interval hovers in its own turn, the rest of the interval once at the frame,
/// at the latest point. Enter, exit and a press land the pending moves first, so a click after fast
/// moves selects the tab under its own point. The strip and the saved groups bar.
@MainActor @Suite(.serialized) struct TabStripPointerTests {
    @MainActor final class Harness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let frames = PointerFrameTestRig()
        /// Every hovered tab the strip reported, in order (`onHoverTab`: one call per hover change).
        var hoverChanges: [TabID?] = []

        init(frameInput: Bool = true) {
            _ = NSApplication.shared
            model = TabStripModel(tabs: (0..<6).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
            strip = TabStripView(model: model, input: InputEventTap())
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            window.isReleasedWhenClosed = false
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            if frameInput { strip.hoverFrameInput = frames.coalescers }
            model.intentHandler = { [unowned self] intent in
                if case .select(let id) = intent { model.selectedID = id }
            }
            strip.onHoverTab = { [unowned self] id in hoverChanges.append(id) }
        }

        /// A point inside tab `index`, away from its close button, in window coordinates.
        func point(_ index: Int) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID("t\(index)")], "no cell for t\(index)")
            return strip.convert(strip.convert(CGPoint(x: cell.frame.minX + 12, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        }

        func event(_ type: NSEvent.EventType, tab index: Int) throws -> NSEvent {
            try TabStripPointerTests.mouse(type, at: try point(index), in: window)
        }

        func move(to index: Int) throws { strip.mouseMoved(with: try event(.mouseMoved, tab: index)) }

        func close() {
            frames.close()
            window.close()
        }
    }

    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    static func exit(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                            userData: nil))
    }

    // MARK: The strip

    /// A lone move after an idle frame hovers in the same turn: the frame-aligned path adds no wait.
    @Test func aSingleMoveAfterAnIdleFrameHoversInTheSameTurn() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 3)
        #expect(harness.hoverChanges == [TabID("t3")])
        #expect(harness.strip.hoveredID == TabID("t3"))
        #expect(!harness.frames.coalescer.hasPending, "nothing waits for the frame")
    }

    /// Eight moves across the strip in one frame: the first hovers at once, the other seven once at
    /// the frame, the tab under the last move. Two hovers, no more.
    @Test func eightMovesInOneFrameHoverTwiceTheLeadingAndTheLatestTab() throws {
        let harness = Harness()
        defer { harness.close() }
        for step in 0..<8 { try harness.move(to: step % 6) }
        #expect(harness.hoverChanges == [TabID("t0")], "before the frame only the leading move hovered")
        #expect(harness.frames.coalescer.hasPending)
        harness.frames.frame()
        #expect(harness.hoverChanges == [TabID("t0"), TabID("t\(7 % 6)")])
        #expect(harness.strip.hoveredID == TabID("t\(7 % 6)"))
        #expect(harness.strip.frameInputHover.maxDeliveriesPerFrame == 2)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// A press after fast moves selects the tab under the press, and no move of the frame before it
    /// is left for a later frame to hover.
    @Test func aClickAfterFastMovesSelectsTheTabUnderTheClick() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        harness.frames.frame()
        for index in [2, 3, 4] { try harness.move(to: index) }
        #expect(harness.strip.hoveredID == TabID("t2"), "the interval's leading move hovered; 3 and 4 wait")
        #expect(harness.frames.coalescer.hasPending)
        harness.strip.mouseDown(with: try harness.event(.leftMouseDown, tab: 4))
        #expect(!harness.frames.coalescer.hasPending, "the press left moves for a later frame")
        #expect(harness.strip.hoveredID == TabID("t4"), "the press saw a stale hover")
        harness.strip.mouseUp(with: try harness.event(.leftMouseUp, tab: 4))
        #expect(harness.model.selectedID == TabID("t4"))
    }

    /// Leaving the strip lands the pending moves before it clears the hover: a frame after the exit
    /// lights no tab.
    @Test func anExitFlushesThePendingMovesThenClearsTheHover() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 2)
        try harness.move(to: 3)
        #expect(harness.frames.coalescer.hasPending)
        harness.strip.mouseExited(with: try TabStripPointerTests.exit(at: try harness.point(3), in: harness.window))
        #expect(!harness.frames.coalescer.hasPending)
        #expect(harness.hoverChanges.prefix(2) == [TabID("t2"), TabID("t3")], "the exit landed the pending move first")
        #expect(harness.strip.hoveredID == nil)
        harness.frames.frame()
        #expect(harness.strip.hoveredID == nil, "a move delivered after the exit lit a tab")
    }

    /// With the feature off (no frame-aligned input), every move hovers at once.
    @Test func withoutFrameInputEveryMoveHovers() throws {
        let harness = Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(to: index) }
        #expect(harness.hoverChanges == (0..<4).map { Optional(TabID("t\($0)")) })
        #expect(!harness.frames.coalescer.hasPending)
    }

    // MARK: The saved groups bar

    /// The saved groups bar: a lone move hovers at once, a frame's later moves once at the frame (the
    /// latest chip), and a press lands them first.
    @Test func theSavedGroupsBarHoversOnTheLeadingEdgeAndOnceAtTheFrame() throws {
        _ = NSApplication.shared
        let frames = PointerFrameTestRig()
        defer { frames.close() }
        let ids: [TabGroupID] = ["saved-a", "saved-b", "saved-c", "saved-d"]
        let model = SavedGroupsBarModel(groups: ids.map { SavedTabGroupItem(id: $0, name: "\($0)", colorToken: .blue, tabCount: 2) })
        let bar = SavedGroupsBarView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: SavedGroupsBarView.preferredHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = bar
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: SavedGroupsBarView.preferredHeight)
        bar.layoutSubtreeIfNeeded()
        bar.hoverFrameInput = frames.coalescers
        func point(_ index: Int) throws -> CGPoint {
            let chip = try #require(bar.chips[ids[index]], "no chip for \(ids[index])")
            return bar.convert(CGPoint(x: chip.frame.minX + 4, y: chip.frame.midY), to: nil)
        }
        func move(to index: Int) throws { bar.mouseMoved(with: try Self.mouse(.mouseMoved, at: try point(index), in: window)) }

        try move(to: 1)
        #expect(bar.hovered == ids[1], "the lone move hovered in its own turn")
        for index in [2, 3, 0, 2] { try move(to: index) }
        #expect(bar.hovered == ids[1], "the interval's later moves wait for the frame")
        frames.frame()
        #expect(bar.hovered == ids[2], "the frame hovered the latest chip")

        try move(to: 0)
        try move(to: 3)
        #expect(bar.hovered == ids[0])
        bar.mouseDown(with: try Self.mouse(.leftMouseDown, at: try point(3), in: window))
        #expect(bar.hovered == ids[3], "the press landed the pending move first")
        #expect(!frames.coalescer.hasPending)
    }
}
