import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import QuartzCore
import Testing

/// chrome-parity p03-rendering-101: the collapsed toolbar band's open and close set its share once
/// and lay the top row out once, at rest; additive render-server springs show the band, and what
/// follows it, moving there, and a change mid-flight keeps the presented width continuous. No frame
/// of the motion lays the row out (the band used to animate a width constraint per frame).
///
/// The row's layer has `speed` 0, so the springs' clock is its `timeOffset`: each read sets it and
/// samples the presentation layer at exactly that time (as `RenderSpringParityTests` do).
@MainActor @Suite(.serialized) struct CollapsedBandRevealMotionTests {
    /// A top row like the window root's: the band as wide as the share, faded with it, and an
    /// accessory after it. It counts its layouts.
    final class Row: NSView {
        let band = NSView(frame: .zero)
        let follower = NSView(frame: .zero)
        var share: () -> CGFloat = { 0 }
        private(set) var layouts = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for view in [band, follower] {
                view.wantsLayer = true
                addSubview(view)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            layouts += 1
            band.frame = CGRect(x: 80, y: 10, width: TitlebarToolbarBand.width * share(), height: 20)
            band.alphaValue = share()
            follower.frame = CGRect(x: band.frame.maxX + 8, y: 10, width: 40, height: 20)
        }

        /// Stops the row's clock at `time` seconds.
        func seek(_ time: CFTimeInterval) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.speed = 0
            layer?.timeOffset = time
            CATransaction.commit()
            CATransaction.flush()
        }

        /// The band's presented width at `time` seconds.
        func presentedBandWidth(at time: CFTimeInterval) throws -> CGFloat {
            seek(time)
            return try #require(band.layer?.presentation(), "no presentation layer after a commit").bounds.width
        }

        func springKeys(of view: NSView) -> [String] {
            (view.layer?.animationKeys() ?? []).filter { $0.hasPrefix("cmux.renderSpring.") }
        }
    }

    /// A reveal over a hidden sidebar, installed in a row laid out closed, the clock at 0.
    static func collapsed() -> (MainDeadlineRig, CollapsedBandReveal, Row) {
        let rig = MainDeadlineRig(), reveal = CollapsedBandReveal(deadlines: rig.deadlines)
        let row = Row(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        row.share = { [unowned reveal] in reveal.presence }
        row.seek(0)
        row.layoutSubtreeIfNeeded()
        reveal.install(in: row)
        reveal.riders = { [unowned row] in (row.band, [row.follower]) }
        reveal.setSidebarHidden(true)
        return (rig, reveal, row)
    }

    static func withMotion<T>(reduced: Bool = false, _ body: () throws -> T) throws -> T {
        Motion.reduceMotionOverride = reduced
        defer { Motion.reduceMotionOverride = nil }
        if !reduced { try #require(Motion.sidebar.animatesMovement, "sidebar movement is off in this host's settings") }
        return try body()
    }

    @Test func anOpenLaysTheRowOutOnceAtRestAndSpringsItFromWhereItShowed() throws {
        try Self.withMotion {
            let (rig, reveal, row) = Self.collapsed()
            let layouts = row.layouts
            reveal.setEngaged(true)
            #expect(reveal.isOpen)
            #expect(reveal.presence == 1, "the share is at rest at once")
            #expect(row.layouts == layouts + 1, "an open is one layout, not one per frame")
            #expect(row.band.frame.width == TitlebarToolbarBand.width, "the band's frame is at rest at once")
            #expect(reveal.lastChangeAnimated)
            #expect(row.band.clipsToBounds, "the band clips to its springing width")
            #expect(row.springKeys(of: row.band).contains { $0.hasSuffix(".bounds.size") })
            #expect(row.springKeys(of: row.follower).contains { $0.hasSuffix(".position") })
            let shown = try row.presentedBandWidth(at: 0)
            #expect(abs(shown) < 0.01, "the band starts from the width it showed: \(shown)")
            withExtendedLifetime(rig) {}
        }
    }

    @Test func openCloseOpenMidFlightKeepsThePresentedWidthContinuous() throws {
        try Self.withMotion {
            let (rig, reveal, row) = Self.collapsed()
            let layouts = row.layouts
            reveal.setEngaged(true)
            let opening = try row.presentedBandWidth(at: 0.05)
            #expect(opening > 0.5 && opening < TitlebarToolbarBand.width - 0.5, "mid-open: \(opening)")

            reveal.setEngaged(false)
            rig.fireAndRun() // the close delay ends: the close starts at the row's clock, 0.05 s in
            #expect(!reveal.isOpen)
            #expect(reveal.presence == 0)
            #expect(row.band.frame.width == 0, "the band's frame is at rest at once")
            let closing = try row.presentedBandWidth(at: 0.05)
            #expect(abs(closing - opening) < 0.01, "the close starts where the open showed: \(opening) then \(closing)")

            let midClose = try row.presentedBandWidth(at: 0.1)
            reveal.setEngaged(true)
            let reopening = try row.presentedBandWidth(at: 0.1)
            #expect(abs(reopening - midClose) < 0.01, "the reopen starts where the close showed: \(midClose) then \(reopening)")
            #expect(row.band.frame.width == TitlebarToolbarBand.width)
            #expect(row.layouts == layouts + 3, "three changes, three layouts")
            #expect(row.band.clipsToBounds, "still in flight")
        }
    }

    @Test func reduceMotionPlacesTheBandInOneFrameWithNoClip() throws {
        try Self.withMotion(reduced: true) {
            let (rig, reveal, row) = Self.collapsed()
            let layouts = row.layouts
            reveal.setEngaged(true)
            #expect(row.layouts == layouts + 1)
            #expect(!reveal.lastChangeAnimated)
            #expect(!row.band.clipsToBounds)
            #expect(!row.springKeys(of: row.band).contains { $0.hasSuffix(".bounds.size") || $0.hasSuffix(".position") })
            #expect(row.band.frame.width == TitlebarToolbarBand.width)
            withExtendedLifetime(rig) {}
        }
    }
}
