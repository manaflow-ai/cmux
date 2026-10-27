import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Foundation
import ObjectiveC
import Testing

/// Spike p04-input-102 (input-pipeline-DESIGN.md I4, "Spike 102"): the strip host AppKit can scroll on its own
/// thread keeps every class responsive-scroll compatible with no `scrollWheel(_:)` of its own, keeps the
/// keep-alive band prepared, and lands each live scroll on the column scroll reducer's snap.
@MainActor
struct StripScrollHostTests {
    /// The event clock the host's gesture samples read.
    final class Clock {
        var time: TimeInterval = 100
    }

    /// Five 600 pt columns, 16 pt apart, in a 1000 pt viewport (the rows variant runs the same strip down).
    private static func strip(axis: SplitAxis = .horizontal) -> ColumnStrip {
        let columns = (0..<5).map { index in
            ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: CGFloat(index) * 616, y: 0, width: 600, height: 800),
                               panes: [PaneID("p\(index)")])
        }
        var strip = ColumnStrip(columns: columns, viewportWidth: 1000, contentWidth: 5 * 616 - 16, gap: 16)
        strip.axis = axis
        return strip
    }

    private static func host(axis: SplitAxis = .horizontal, clock: Clock = Clock()) -> StripScrollHost {
        let size = axis == .horizontal ? NSSize(width: 1000, height: 800) : NSSize(width: 800, height: 1000)
        return StripScrollHost(frame: NSRect(origin: .zero, size: size), axis: axis,
                               landingSpring: Motion.panes.renderSpring(.scroll), now: { clock.time })
    }

    private static func scroll(_ host: StripScrollHost, to value: CGFloat) {
        let origin = host.axis == .horizontal ? NSPoint(x: value, y: 0) : NSPoint(x: 0, y: value)
        host.contentView.scroll(to: origin)
    }

    private static func expectedSnap(release: CGFloat, strip: ColumnStrip) -> CGFloat {
        let snaps = ColumnViewOffset.snaps(strip: strip, mode: .never).map(\.offset)
        return ColumnStripGeometry.snapTarget(releaseOffset: release, velocity: 0, snaps: snaps)
    }

    // MARK: Responsive scrolling

    @Test func everyClassIsResponsiveScrollCompatible() {
        let host = Self.host()
        #expect(StripScrollHost.isCompatibleWithResponsiveScrolling)
        #expect(StripScrollClipView.isCompatibleWithResponsiveScrolling)
        #expect(StripScrollDocumentView.isCompatibleWithResponsiveScrolling)
        #expect(host.contentView is StripScrollClipView)
        #expect(host.documentView === host.document)
    }

    /// AppKit leaves responsive scrolling for a scroll view whose classes take `scrollWheel(_:)`; none does.
    @Test func noClassImplementsScrollWheel() {
        let wheel = #selector(NSResponder.scrollWheel(with:))
        let pairs: [(AnyClass, AnyClass)] = [(StripScrollHost.self, NSScrollView.self), (StripScrollClipView.self, NSClipView.self),
                                             (StripScrollDocumentView.self, NSView.self)]
        for (cls, base) in pairs {
            #expect(class_getInstanceMethod(cls, wheel) == class_getInstanceMethod(base, wheel), "\(cls) implements scrollWheel")
        }
    }

    @Test func theKeepAliveBandIsOneViewportPastEachEnd() {
        let bounds = NSRect(x: 0, y: 0, width: 3064, height: 800)
        let middle = NSRect(x: 1000, y: 0, width: 1000, height: 800)
        #expect(StripScrollDocumentView.keepAliveBand(around: middle, prepared: middle, bounds: bounds, axis: .horizontal)
            == NSRect(x: 0, y: 0, width: 3000, height: 800))
        let end = NSRect(x: 2064, y: 0, width: 1000, height: 800)
        #expect(StripScrollDocumentView.keepAliveBand(around: end, prepared: end, bounds: bounds, axis: .horizontal)
            == NSRect(x: 1064, y: 0, width: 2000, height: 800))
        let rows = NSRect(x: 0, y: 0, width: 800, height: 3064)
        let visibleRows = NSRect(x: 0, y: 500, width: 800, height: 1000)
        #expect(StripScrollDocumentView.keepAliveBand(around: visibleRows, prepared: visibleRows, bounds: rows, axis: .vertical)
            == NSRect(x: 0, y: 0, width: 800, height: 2500))
    }

    @Test func preparingContentKeepsTheBand() {
        let host = Self.host()
        host.show(Self.strip(), focused: PaneID("p0"), source: .programmatic)
        Self.scroll(host, to: 1000)
        let visible = host.documentVisibleRect
        host.document.prepareContent(in: visible)
        #expect(host.document.preparedContentRect == NSRect(x: 0, y: 0, width: 3000, height: 800))
    }

    // MARK: The reducer

    @Test func aSnapshotSizesTheDocumentAndRevealsTheFocusedColumn() {
        let host = Self.host()
        let strip = Self.strip()
        host.show(strip, focused: PaneID("p0"), source: .programmatic)
        #expect(host.document.frame.size == NSSize(width: 3064, height: 800))
        #expect(host.offset == 0)
        host.show(strip, focused: PaneID("p3"), source: .keyboard)
        let target = host.scrollState.spring.target
        #expect(target > 0)
        #expect(host.offset == target)
        #expect(host.scrollState.spring.value == target)
        // The landing springs the translation to rest: its model is at rest at once.
        #expect(host.document.layer?.sublayerTransform.m41 == 0)
    }

    @Test func aLiveScrollLandsOnTheReducersSnap() throws {
        let clock = Clock()
        let host = Self.host(clock: clock)
        let strip = Self.strip()
        host.show(strip, focused: PaneID("p0"), source: .programmatic)
        host.liveScrollBegan()
        #expect(host.isLiveScrolling)
        for value: CGFloat in [150, 400, 700] {
            clock.time += 0.2
            Self.scroll(host, to: value)
        }
        clock.time += 0.2
        let landed = host.liveScrollEnded()
        let target = try #require(landed)
        #expect(target == Self.expectedSnap(release: 700, strip: strip))
        #expect(host.offset == target)
        #expect(!host.isLiveScrolling)
        #expect(host.document.layer?.sublayerTransform.m41 == 0)
    }

    /// A stall's catch-up: the main thread sees AppKit's moves as one small and one large delta 10 ms apart
    /// just before the end, after AppKit's momentum already stopped. That is no release velocity (it would
    /// read 45,000 pt/s and coast to the strip's end): the strip snaps to the snap nearest where it rests.
    @Test func aStallsCatchUpAtTheEndLandsOnTheNearestSnap() throws {
        let clock = Clock()
        let host = Self.host(clock: clock)
        let strip = Self.strip()
        host.show(strip, focused: PaneID("p0"), source: .programmatic)
        host.liveScrollBegan()
        Self.scroll(host, to: 50)
        clock.time += 0.01
        Self.scroll(host, to: 450)
        let landed = host.liveScrollEnded()
        let target = try #require(landed)
        let snaps = ColumnViewOffset.snaps(strip: strip, mode: .never).map(\.offset)
        let coasted = ColumnStripGeometry.snapTarget(releaseOffset: 450, velocity: 45_000, snaps: snaps)
        #expect(target == Self.expectedSnap(release: 450, strip: strip))
        #expect(target != coasted)
        #expect(host.offset == target)
    }

    /// AppKit moving the clip is a gesture sample through the clip's own hook: nothing takes `scrollWheel(_:)`
    /// and nothing observes a bounds notification.
    @Test func clipMovesFeedTheGestureThroughTheClipsHook() throws {
        let clock = Clock()
        let host = Self.host(clock: clock)
        let strip = Self.strip()
        host.show(strip, focused: PaneID("p0"), source: .programmatic)
        // Outside a live scroll a clip move is no sample.
        host.contentView.setBoundsOrigin(NSPoint(x: 40, y: 0))
        #expect(host.scrollState.gesture == nil)
        host.contentView.setBoundsOrigin(.zero)
        host.liveScrollBegan()
        clock.time += 0.2
        host.contentView.setBoundsOrigin(NSPoint(x: 900, y: 0))
        let gesture = try #require(host.scrollState.gesture)
        #expect(gesture.raw == 900)
        clock.time += 0.2
        host.liveScrollEnded()
        #expect(!host.isLiveScrolling)
        #expect(host.offset == Self.expectedSnap(release: 900, strip: strip))
    }

    /// The prototype's own rule, not an observed AppKit limit: during a live scroll the host does not move
    /// the clip (``StripScrollHost/show(_:focused:source:)``); a snapshot syncs the reducer and the gesture's
    /// end lands on its target.
    @Test func aSnapshotDuringALiveScrollDoesNotMoveTheClip() {
        let clock = Clock()
        let host = Self.host(clock: clock)
        let strip = Self.strip()
        host.show(strip, focused: PaneID("p0"), source: .programmatic)
        host.liveScrollBegan()
        clock.time += 0.2
        Self.scroll(host, to: 300)
        host.show(strip, focused: PaneID("p3"), source: .keyboard)
        #expect(host.offset == 300)
        #expect(host.isLiveScrolling)
    }

    @Test func rowsScrollDown() throws {
        let clock = Clock()
        let host = Self.host(axis: .vertical, clock: clock)
        let strip = Self.strip(axis: .vertical)
        host.show(strip, focused: PaneID("p0"), source: .programmatic)
        #expect(host.document.frame.size == NSSize(width: 800, height: 3064))
        host.liveScrollBegan()
        clock.time += 0.2
        Self.scroll(host, to: 1300)
        clock.time += 0.2
        let landed = host.liveScrollEnded()
        let target = try #require(landed)
        #expect(target == Self.expectedSnap(release: 1300, strip: strip))
        #expect(host.contentView.bounds.origin.y == target)
        #expect(host.contentView.bounds.origin.x == 0)
        #expect(host.document.layer?.sublayerTransform.m42 == 0)
    }
}
