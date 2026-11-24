import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextWakeupsTestSupport

/// Lawrence 2026-11-20 (msg 42498): "for scrollbar, it is possible for me to hover close, and for the
/// width to change, but after i mousedown and drag, it fails to scroll. fix so we get it pixel
/// perfect". The pointer widened the knob 20 pt from the edge, but a press landed on the scroller only
/// on the drawn knob (about 11 pt wide, and never on the track beside it): the pixels between were a
/// wide knob that a press went past. One zone now decides both, column by column: the knob widens
/// under the pointer exactly where a press grabs it (or pages the track), and a grabbed knob follows
/// the pointer 1:1, also once the pointer leaves the bar.
@MainActor
@Suite(.serialized)
struct ThinScrollerGrabZoneTests {
    /// A borderless window with a 240 x 200 scroll view (the shared thin scroller on both bars) over
    /// content four times its size, scrolled to the top left.
    private struct Fixture {
        let window: NSWindow
        let container: NSView
        let scrollView: NSScrollView

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
            window.contentView = container
            scrollView = NSScrollView(frame: container.bounds)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.verticalScroller = ThinScroller(frame: NSRect(x: 0, y: 0, width: 11, height: 200),
                                                       clock: ManualClock(), notificationCenter: NotificationCenter())
            scrollView.horizontalScroller = ThinScroller(frame: NSRect(x: 0, y: 0, width: 240, height: 11),
                                                         clock: ManualClock(), notificationCenter: NotificationCenter())
            SystemScrollers.follow(scrollView)
            scrollView.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 960, height: 800))
            container.addSubview(scrollView)
            scrollView.tile()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func scroller(_ axis: Axis) -> ThinScroller {
            let bar = axis == .vertical ? scrollView.verticalScroller : scrollView.horizontalScroller
            guard let thin = bar as? ThinScroller else { preconditionFailure("SystemScrollers.follow keeps the thin scroller on both bars") }
            return thin
        }

        /// The clip's origin along `axis`.
        func offset(_ axis: Axis) -> CGFloat {
            axis == .vertical ? scrollView.contentView.bounds.origin.y : scrollView.contentView.bounds.origin.x
        }

        func reset() {
            for axis in Axis.allCases { scroller(axis).pointerMoved(to: nil) }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// The pointer moves to `point` (window coordinates): the scroll view's tracking area tells each bar.
        func hover(_ point: CGPoint) {
            let local = scrollView.convert(point, from: nil)
            let inside = scrollView.bounds.contains(local)
            for axis in Axis.allCases {
                scroller(axis).pointerMoved(to: inside ? local : nil)
            }
        }

        /// What a press at `point` (window coordinates) lands on.
        func target(at point: CGPoint) -> NSView? {
            container.hitTest(container.superview?.convert(point, from: nil) ?? point)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }

        /// A press at `from`, a drag through `path`, a release at its last point, through what the
        /// press lands on. Returns false when the press does not land on `scroller`.
        func press(_ scroller: ThinScroller, at from: CGPoint, dragTo path: [CGPoint]) -> Bool {
            guard target(at: from) === scroller else { return false }
            drain()
            for point in path { NSApp.postEvent(event(.leftMouseDragged, at: point), atStart: false) }
            NSApp.postEvent(event(.leftMouseUp, at: path.last ?? from), atStart: false)
            scroller.mouseDown(with: event(.leftMouseDown, at: from))
            drain()
            return true
        }

        /// Drops mouse events a press left in the queue.
        func drain() {
            while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        }
    }

    nonisolated enum Axis: CaseIterable, Sendable { case vertical, sideways }

    /// The knob's start along `axis` in window points, measured from the top (a sideways one: the left).
    private static func knobStart(_ scroller: ThinScroller, _ axis: Axis) -> CGFloat {
        let knob = scroller.convert(scroller.rect(for: .knob), to: nil)
        return axis == .vertical ? -knob.maxY : knob.minX
    }

    /// A point `across` points in from the bar's outer edge (window coordinates), at `along` on the
    /// bar's axis (from the top, a sideways bar: from the left).
    private static func point(_ fixture: Fixture, _ axis: Axis, across: CGFloat, along: CGFloat) -> CGPoint {
        let frame = fixture.scrollView.convert(fixture.scrollView.bounds, to: nil)
        return axis == .vertical
            ? CGPoint(x: frame.maxX - across, y: frame.maxY - along)
            : CGPoint(x: frame.minX + along, y: frame.minY + across)
    }

    /// The knob's middle along `axis`, from the top (left), in window points.
    private static func knobMiddle(_ fixture: Fixture, _ axis: Axis) -> CGFloat {
        let scroller = fixture.scroller(axis)
        let knob = scroller.convert(scroller.rect(for: .knob), to: nil)
        let frame = fixture.scrollView.convert(fixture.scrollView.bounds, to: nil)
        return axis == .vertical ? frame.maxY - knob.midY : knob.midX - frame.minX
    }

    /// Every pixel column from the bar's outer edge into the content, on the knob and on the track
    /// beside it: the knob is wide under the pointer exactly where a press lands on the scroller.
    @Test(arguments: Axis.allCases)
    func theKnobWidensExactlyWhereAPressGrabsIt(axis: Axis) throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        let scroller = fixture.scroller(axis)
        try #require(scroller.knobProportion < 1)
        let depth = axis == .vertical ? fixture.scrollView.bounds.width : fixture.scrollView.bounds.height
        let rows: [(String, CGFloat)] = [("knob", Self.knobMiddle(fixture, axis)), ("track", 150)]
        var mismatches: [String] = []
        var widened: [String: [Int]] = [:]
        for (name, along) in rows {
            for column in 0..<Int(depth) {
                fixture.reset()
                let point = Self.point(fixture, axis, across: CGFloat(column) + 0.5, along: along)
                fixture.hover(point)
                let wide = scroller.isKnobExpanded
                let grabs = fixture.target(at: point) === scroller
                if wide { widened[name, default: []].append(column) }
                if wide != grabs { mismatches.append("\(name) column \(column): wide \(wide), press grabs \(grabs)") }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
        // The zone is one run of columns from the outer edge in, the same on the knob and the track.
        let knobColumns = widened["knob"] ?? []
        #expect(!knobColumns.isEmpty)
        #expect(knobColumns == Array(0..<knobColumns.count))
        #expect(widened["track"] == knobColumns)
    }

    /// From every column where the knob is wide, a press on the knob and a drag move the knob with
    /// the pointer, point for point, and scroll the content.
    @Test(arguments: Axis.allCases)
    func aDragFromEveryWideColumnMovesTheKnobOneToOne(axis: Axis) throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        let scroller = fixture.scroller(axis)
        let depth = axis == .vertical ? fixture.scrollView.bounds.width : fixture.scrollView.bounds.height
        var failures: [String] = []
        var dragged = 0
        for column in 0..<Int(depth) {
            fixture.reset()
            let along = Self.knobMiddle(fixture, axis)
            let from = Self.point(fixture, axis, across: CGFloat(column) + 0.5, along: along)
            fixture.hover(from)
            guard scroller.isKnobExpanded else { continue }
            let start = Self.knobStart(scroller, axis)
            let to = Self.point(fixture, axis, across: CGFloat(column) + 0.5, along: along + 30)
            guard fixture.press(scroller, at: from, dragTo: [to]) else {
                failures.append("column \(column): wide, but the press went past the scroller")
                continue
            }
            dragged += 1
            let moved = Self.knobStart(scroller, axis) - start
            if abs(moved - 30) > 0.5 { failures.append("column \(column): knob moved \(moved) for a 30 pt drag") }
            if fixture.offset(axis) <= 0 { failures.append("column \(column): the content did not scroll") }
        }
        #expect(dragged > 0)
        #expect(failures.isEmpty, "\(failures)")
    }

    /// A grabbed knob keeps following the pointer after it leaves the bar for the content, and
    /// beyond the window: the drag ends only at the release.
    @Test(arguments: Axis.allCases)
    func aDragKeepsTrackingAfterThePointerLeavesTheBar(axis: Axis) throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        let scroller = fixture.scroller(axis)
        let along = Self.knobMiddle(fixture, axis)
        let from = Self.point(fixture, axis, across: 4, along: along)
        fixture.hover(from)
        let start = Self.knobStart(scroller, axis)
        let path = [Self.point(fixture, axis, across: 60, along: along + 10),
                    Self.point(fixture, axis, across: 120, along: along + 25),
                    Self.point(fixture, axis, across: -40, along: along + 40)]
        #expect(fixture.press(scroller, at: from, dragTo: path))
        #expect(abs(Self.knobStart(scroller, axis) - start - 40) <= 0.5)
        // Released away from the bar: the knob is no longer held wide.
        #expect(!scroller.isKnobExpanded)
    }

    /// A press on the track beside the knob, where the knob is wide, scrolls toward the press.
    @Test(arguments: Axis.allCases)
    func aPressOnTheTrackScrollsTowardIt(axis: Axis) throws {
        let fixture = Fixture()
        defer { fixture.window.close() }
        let scroller = fixture.scroller(axis)
        let point = Self.point(fixture, axis, across: 4, along: 150)
        fixture.hover(point)
        #expect(scroller.isKnobExpanded)
        #expect(fixture.press(scroller, at: point, dragTo: []))
        #expect(fixture.offset(axis) > 0)
    }
}

/// A document with its origin at the top left, like the app's lists.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
