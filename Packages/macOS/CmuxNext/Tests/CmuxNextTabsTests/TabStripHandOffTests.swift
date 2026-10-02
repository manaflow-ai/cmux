import AppKit
import Testing
@testable import CmuxNextTabs

/// Dogfood nxdog13: "when i drag a tab, my mouse's relative position on the
/// tab should never change". A tab dragged out of its strip is handed to the
/// App's drag session with the point the user grabbed, in the tab's own
/// coordinates, so the floating ghost keeps that point under the pointer.
/// The strip is the top-left strip of a minimal-titlebar window (the top
/// row, next to the traffic lights), where the titlebar blocker lives.
@MainActor @Suite(.serialized) struct TabStripHandOffTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView
        var intents: [TabStripIntent] = []

        init(titles: [String]) {
            let tabs = titles.enumerated().map { TabItem(id: TabID("t\($0.offset)"), title: $0.element) }
            model = TabStripModel(tabs: tabs, selectedID: tabs.first?.id)
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            window.contentView = root
            strip.frame = NSRect(x: 100, y: 400 - TabStripView.preferredHeight, width: 800, height: TabStripView.preferredHeight)
            root.addSubview(strip)
            strip.sync(fromModel: true)
            strip.layoutSubtreeIfNeeded()
            strip.relayout(animated: false)
            model.intentHandler = { [weak self] in self?.intents.append($0) }
        }

        /// Strip-local point `dx` into tab `index` and `y` from the strip top.
        func point(inTab index: Int, dx: CGFloat, y: CGFloat) -> CGPoint {
            let cell = strip.cells[TabID("t\(index)")]!
            return strip.tabsClip.convert(CGPoint(x: cell.frame.minX + dx, y: y), to: strip)
        }

        /// Screen frame of tab `index` now.
        func screenFrame(ofTab index: Int) -> CGRect {
            let cell = strip.cells[TabID("t\(index)")]!
            return window.convertToScreen(strip.tabsClip.convert(cell.frame, to: nil))
        }

        func event(_ type: NSEvent.EventType, at stripPoint: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: strip.convert(stripPoint, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }

        var dragStart: TabDragStart? {
            intents.lazy.compactMap { if case .dragBegan(let start) = $0 { start } else { nil } }.first
        }

        func close() { window.close() }
    }

    @Test func aPressOnATopRowTabReachesTheStrip() throws {
        let h = Harness(titles: ["One", "Two", "Three"])
        defer { h.close() }
        let frameView = try #require(h.window.contentView?.superview)
        for index in 0..<3 {
            let point = h.strip.convert(h.point(inTab: index, dx: 12, y: h.strip.bounds.midY), to: nil)
            #expect(frameView.hitTest(frameView.convert(point, from: nil)) === h.strip, "tab \(index)")
        }
    }

    /// Pressed 18 pt into the tab, 9 pt below the strip top, then dragged
    /// straight down out of the strip: the hand-off carries exactly that
    /// point, whatever the tear-off distance.
    @Test func theHandOffCarriesThePointTheUserGrabbed() throws {
        let h = Harness(titles: ["One", "Two", "Three"])
        defer { h.close() }
        let press = h.point(inTab: 1, dx: 18, y: 9)
        let tabAtPress = h.screenFrame(ofTab: 1)
        let pressOnScreen = h.window.convertPoint(toScreen: h.strip.convert(press, to: nil))
        let grabbed = CGPoint(x: pressOnScreen.x - tabAtPress.minX, y: pressOnScreen.y - tabAtPress.minY)

        h.strip.mouseDown(with: h.event(.leftMouseDown, at: press))
        for step in 1...12 {
            h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: CGPoint(x: press.x, y: press.y + CGFloat(step) * 8)))
        }
        let start = try #require(h.dragStart)
        #expect(abs(start.grabOffset.x - grabbed.x) < 0.5, "x \(start.grabOffset.x) != \(grabbed.x)")
        #expect(abs(start.grabOffset.y - grabbed.y) < 0.5, "y \(start.grabOffset.y) != \(grabbed.y)")
        // The ghost starts where the tab was.
        #expect(abs(start.screenFrame.minX - tabAtPress.minX) < 0.5 && abs(start.screenFrame.minY - tabAtPress.minY) < 0.5)
    }

    /// Dragged diagonally past the strip's end first (the tab stops at the
    /// last slot while the pointer keeps going): still the grabbed point.
    @Test func theGrabbedPointSurvivesAClampedReorder() throws {
        let h = Harness(titles: ["One", "Two"])
        defer { h.close() }
        let press = h.point(inTab: 1, dx: 30, y: 14)
        let tabAtPress = h.screenFrame(ofTab: 1)
        let pressOnScreen = h.window.convertPoint(toScreen: h.strip.convert(press, to: nil))
        let grabbed = CGPoint(x: pressOnScreen.x - tabAtPress.minX, y: pressOnScreen.y - tabAtPress.minY)

        h.strip.mouseDown(with: h.event(.leftMouseDown, at: press))
        for step in 1...20 {
            h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: CGPoint(x: press.x + CGFloat(step) * 30, y: press.y + CGFloat(step) * 4)))
        }
        let start = try #require(h.dragStart)
        #expect(abs(start.grabOffset.x - grabbed.x) < 0.5, "x \(start.grabOffset.x) != \(grabbed.x)")
        #expect(abs(start.grabOffset.y - grabbed.y) < 0.5, "y \(start.grabOffset.y) != \(grabbed.y)")
    }

    /// Top-row strips sit side by side (one per pane). Dragging a tab
    /// sideways past the strip's end hands it to the drag session, so it can
    /// land in the neighbor pane's strip without leaving the row first
    /// (tagged build tdrag2: the drag stayed a clamped reorder).
    @Test func draggingSidewaysPastTheStripEndHandsOff() throws {
        let h = Harness(titles: ["One", "Two"])
        defer { h.close() }
        let press = h.point(inTab: 1, dx: 20, y: 14)
        h.strip.mouseDown(with: h.event(.leftMouseDown, at: press))
        let end = h.strip.bounds.width + 60
        for step in 1...20 {
            h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: CGPoint(x: press.x + (end - press.x) * CGFloat(step) / 20, y: press.y)))
        }
        #expect(h.dragStart != nil)
    }

    @Test func draggingSidewaysPastTheLeadingEdgeHandsOff() throws {
        let h = Harness(titles: ["One", "Two"])
        defer { h.close() }
        let press = h.point(inTab: 0, dx: 20, y: 14)
        h.strip.mouseDown(with: h.event(.leftMouseDown, at: press))
        for step in 1...20 {
            h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: CGPoint(x: press.x - CGFloat(step) * 10, y: press.y)))
        }
        #expect(h.dragStart != nil)
    }

    /// Dogfood "a tab dropped on its own pane disappears": the strip hides a
    /// handed-off tab for the drag. When the drop lands in the same strip
    /// (the model keeps the tab), ending the drag's presentation shows it
    /// again, at its new place.
    @Test func endingTheDragShowsATabThatLandedInItsOwnStrip() throws {
        let h = Harness(titles: ["One", "Two", "Three"])
        defer { h.close() }
        let press = h.point(inTab: 0, dx: 12, y: 14)
        h.strip.mouseDown(with: h.event(.leftMouseDown, at: press))
        for step in 1...12 {
            h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: CGPoint(x: press.x, y: press.y + CGFloat(step) * 8)))
        }
        _ = try #require(h.dragStart)
        #expect(!h.strip.presentedTabIDs.contains(TabID("t0")))
        // The move landed: t0 is now last in the same strip.
        h.model.tabs = [h.model.tabs[1], h.model.tabs[2], h.model.tabs[0]]
        h.strip.sync(fromModel: true)
        h.strip.restoreDetachedTab(TabID("t0"))
        #expect(h.strip.presentedTabIDs == h.model.orderedTabs.map(\.id))
    }

    @Test func endingTheDragShowsTheOnlyTabDroppedOnItsOwnPane() throws {
        let h = Harness(titles: ["Only"])
        defer { h.close() }
        let press = h.point(inTab: 0, dx: 12, y: 14)
        h.strip.mouseDown(with: h.event(.leftMouseDown, at: press))
        for step in 1...12 {
            h.strip.mouseDragged(with: h.event(.leftMouseDragged, at: CGPoint(x: press.x, y: press.y + CGFloat(step) * 8)))
        }
        _ = try #require(h.dragStart)
        #expect(h.strip.presentedTabIDs.isEmpty)
        h.strip.restoreDetachedTab(TabID("t0"))
        #expect(h.strip.presentedTabIDs == [TabID("t0")])
    }
}
