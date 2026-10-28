import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import QuartzCore
import Testing

/// With `motion.renderServer` on, the collapsed toolbar band's open and close
/// set its share once and lay the top row out once, at rest; additive render-server springs show the band, and
/// what follows it, moving there, and a change mid-flight keeps the presented width continuous. No frame of the
/// motion lays the row out. The band's buttons keep their full size while its clip and fade reveal them, the
/// sidebar's share never adds to a running spring, and only the newest change lands finished. With the switch
/// off, the band steps a width constraint as before (the `cpuStep` variant).
///
/// The row's layer has `speed` 0, so the springs' clock is its `timeOffset`: each read sets it and
/// samples the presentation layer at exactly that time (as `RenderSpringParityTests` do).
@MainActor @Suite(.serialized) struct CollapsedBandRevealMotionTests {
    /// A top row like the window root's: the real toolbar band as wide as the larger of the sidebar's share
    /// and the reveal's, faded with it, and an accessory after it. It counts its layouts.
    final class Row: NSView {
        static let bandX: CGFloat = 80
        let band = TitlebarToolbarBand(frame: .zero)
        let follower = NSView(frame: .zero)
        var share: () -> CGFloat = { 0 }
        /// The sidebar's on-screen share: a test steps it as the sidebar's width animation does.
        var sidebarShare: CGFloat = 0
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
            let presence = max(sidebarShare, share())
            band.presence = presence
            band.frame = CGRect(x: Self.bandX + Metrics.space3 * presence, y: 10,
                                width: TitlebarToolbarBand.width * presence, height: TitlebarBandButton.side)
            follower.frame = CGRect(x: band.frame.maxX + 8, y: 10, width: 40, height: 20)
        }

        /// The open band's trailing edge.
        static var openMaxX: CGFloat { bandX + Metrics.space3 + TitlebarToolbarBand.width }

        /// Stops the row's clock at `time` seconds.
        func seek(_ time: CFTimeInterval) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.speed = 0
            layer?.timeOffset = time
            CATransaction.commit()
            CATransaction.flush()
        }

        /// The band's presented layer at `time` seconds.
        func presentedBand(at time: CFTimeInterval) throws -> CALayer {
            seek(time)
            return try #require(band.layer?.presentation(), "no presentation layer after a commit")
        }

        func springKeys(of view: NSView) -> [String] {
            (view.layer?.animationKeys() ?? []).filter { $0.hasPrefix("cmux.renderSpring.") }
        }
    }

    static func reveal(_ rig: MainDeadlineRig, onServer: Bool) -> CollapsedBandReveal {
        CollapsedBandReveal(deadlines: rig.deadlines, fullWidth: { TitlebarToolbarBand.width }, rendersOnServer: { onServer })
    }

    /// Wires `reveal` to `row` the way the window root does, the sidebar hidden.
    static func install(_ reveal: CollapsedBandReveal, in row: Row) {
        row.share = { [unowned reveal] in reveal.presence }
        row.layoutSubtreeIfNeeded()
        reveal.install(in: row)
        reveal.riders = { [unowned row] in (row.band, [row.follower]) }
        reveal.setSidebarHidden(true)
    }

    /// A reveal over a hidden sidebar, installed in a row laid out closed, the clock at 0.
    static func collapsed(onServer: Bool = true) -> (MainDeadlineRig, CollapsedBandReveal, Row) {
        let rig = MainDeadlineRig(), reveal = Self.reveal(rig, onServer: onServer)
        let row = Row(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        row.seek(0)
        install(reveal, in: row)
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
            #expect(reveal.inFlight)
            #expect(row.band.clipsToBounds, "the band clips to its springing width")
            #expect(row.springKeys(of: row.band).contains { $0.hasSuffix(".bounds.size") })
            #expect(row.springKeys(of: row.follower).contains { $0.hasSuffix(".position") })
            let shown = try row.presentedBand(at: 0).bounds.width
            #expect(abs(shown) < 0.01, "the band starts from the width it showed: \(shown)")
            withExtendedLifetime(rig) {}
        }
    }

    @Test func openCloseOpenMidFlightKeepsThePresentedWidthContinuous() throws {
        try Self.withMotion {
            let (rig, reveal, row) = Self.collapsed()
            let layouts = row.layouts
            reveal.setEngaged(true)
            let opening = try row.presentedBand(at: 0.05).bounds.width
            #expect(opening > 0.5 && opening < TitlebarToolbarBand.width - 0.5, "mid-open: \(opening)")

            reveal.setEngaged(false)
            rig.fireAndRun() // the close delay ends: the close starts at the row's clock, 0.05 s in
            #expect(!reveal.isOpen)
            #expect(reveal.presence == 0)
            #expect(row.band.frame.width == 0, "the band's frame is at rest at once")
            let closing = try row.presentedBand(at: 0.05).bounds.width
            #expect(abs(closing - opening) < 0.01, "the close starts where the open showed: \(opening) then \(closing)")

            let midClose = try row.presentedBand(at: 0.1).bounds.width
            reveal.setEngaged(true)
            let reopening = try row.presentedBand(at: 0.1).bounds.width
            #expect(abs(reopening - midClose) < 0.01, "the reopen starts where the close showed: \(midClose) then \(reopening)")
            #expect(row.band.frame.width == TitlebarToolbarBand.width)
            #expect(row.layouts == layouts + 3, "three changes, three layouts")
            #expect(row.band.clipsToBounds, "still in flight")
        }
    }

    /// The buttons cannot spring their width: they keep their full-size frames through an open, a close and a
    /// reopen mid-flight, and the band's clip and fade reveal them, so a half-closed band shows half of its
    /// buttons instead of none (they used to close up to 0 wide in the close's turn).
    @Test func theBandsButtonsStayFullSizeAndShowThroughOpenCloseAndReopen() throws {
        try Self.withMotion {
            let (rig, reveal, row) = Self.collapsed()
            let buttons = [row.band.sidebarToggle, row.band.backButton, row.band.forwardButton]
            reveal.setEngaged(true)
            let open = buttons.map(\.frame)
            #expect(open.allSatisfy { $0.width == TitlebarBandButton.side }, "the open's buttons are not full size: \(open)")
            #expect(row.band.keepsItemsFullSize)
            _ = try row.presentedBand(at: 0.05)
            reveal.setEngaged(false)
            rig.fireAndRun() // the close starts 0.05 s in
            for time in [0.06, 0.08, 0.1] {
                let shown = try row.presentedBand(at: time)
                #expect(buttons.map(\.frame) == open, "the close moved the buttons in its turn: \(buttons.map(\.frame))")
                #expect(shown.bounds.width > 1 && shown.opacity > 0.01,
                        "the close hid the band at once: \(shown.bounds.width) wide, opacity \(shown.opacity) at \(time) s")
                #expect(buttons.allSatisfy { $0.layer?.animationKeys()?.isEmpty ?? true }, "a button springs on its own")
            }
            reveal.setEngaged(true)
            #expect(buttons.map(\.frame) == open, "the reopen moved the buttons")
            #expect(row.band.keepsItemsFullSize, "still in flight")
        }
    }

    /// The sidebar showing while the band closes: its share never adds to the close's spring, so the band never
    /// shows wider than open or past its open place (an additive close under a model the sidebar raises did).
    @Test func theSidebarShowingDuringACloseNeverTakesTheBandPastOpen() throws {
        try Self.withMotion {
            try #require(Motion.sidebar.spring(.appear).dampingFraction >= 1 && Motion.sidebar.spring(.disappear).dampingFraction >= 1,
                         "this host's structural springs bounce (ui.animations.bounce)")
            let (rig, reveal, row) = Self.collapsed()
            let full = TitlebarToolbarBand.width
            reveal.setEngaged(true)
            row.seek(0.5) // the open shows at rest
            reveal.setEngaged(false)
            rig.fireAndRun() // the close starts at 0.5
            let before = try row.presentedBand(at: 0.502).bounds.width
            reveal.setSidebarHidden(false)
            let after = try row.presentedBand(at: 0.502).bounds.width
            #expect(abs(after - before) < 0.01, "the sidebar's show moved the band: \(before) then \(after)")
            var time = 0.502
            for share in [0.4, 0.8, 1.0] as [CGFloat] {
                row.sidebarShare = share // a frame of the sidebar's width animation
                row.needsLayout = true
                row.layoutSubtreeIfNeeded()
                for _ in 0..<4 {
                    time += 0.004
                    let shown = try row.presentedBand(at: time)
                    #expect(shown.bounds.width <= full + 0.01, "the band shows \(shown.bounds.width) wide (open \(full)) at \(time) s")
                    #expect(shown.frame.maxX <= Row.openMaxX + 0.01, "the band ends at \(shown.frame.maxX) (open \(Row.openMaxX)) at \(time) s")
                }
            }
            let rest = try row.presentedBand(at: 2)
            #expect(abs(rest.bounds.width - full) < 0.01, "the band does not land open: \(rest.bounds.width)")
        }
    }

    @Test func reduceMotionPlacesTheBandInOneFrame() throws {
        try Self.withMotion(reduced: true) {
            let (rig, reveal, row) = Self.collapsed()
            let layouts = row.layouts
            reveal.setEngaged(true)
            #expect(row.layouts == layouts + 1)
            #expect(!reveal.lastChangeAnimated)
            #expect(!row.springKeys(of: row.band).contains { $0.hasSuffix(".bounds.size") || $0.hasSuffix(".position") })
            #expect(row.band.frame.width == TitlebarToolbarBand.width)
            withExtendedLifetime(rig) {}
        }
    }

    /// `motion.renderServer` off (the default until p03-rendering-022c): the open steps the driver's width
    /// constraint, so the change's turn lays nothing out and adds no render-server spring; on, it does both.
    @Test(arguments: [false, true])
    func theRenderServerVariantRunsOnlyWithItsSwitch(onServer: Bool) throws {
        try Self.withMotion {
            let (rig, reveal, row) = Self.collapsed(onServer: onServer)
            let layouts = row.layouts
            reveal.setEngaged(true)
            #expect(reveal.isOpen)
            #expect(reveal.lastChangeAnimated)
            #expect(row.springKeys(of: row.band).isEmpty != onServer, "render-server springs with the switch \(onServer)")
            #expect(row.layouts == layouts + (onServer ? 1 : 0))
            #expect(reveal.inFlight == onServer)
            #expect(row.band.keepsItemsFullSize == onServer)
            withExtendedLifetime(rig) {}
        }
    }

    @Test func theSteppedVariantSetsItsDriverUnderReduceMotion() throws {
        try Self.withMotion(reduced: true) {
            let (rig, reveal, row) = Self.collapsed(onServer: false)
            reveal.setEngaged(true)
            #expect(reveal.driverWidth?.constant == TitlebarToolbarBand.width)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(reveal.presence == 1)
            #expect(row.band.frame.width == TitlebarToolbarBand.width)
            reveal.setEngaged(false)
            rig.fireAndRun()
            #expect(reveal.driverWidth?.constant == 0)
        }
    }

    /// Open, close and reopen mid-flight, run to the end on a real display: the two changes taken over land
    /// not finished at once, in order; the newest lands finished once, and only then does the band draw its
    /// items unclipped and close them up to its share again.
    @Test(.enabled("needs an awake display and animations on, or every change snaps") { await GUIAnimationTestSupport.animatesHere() })
    func openCloseOpenMidFlightLandsFinishedOnceAndUnclipsTheBand() async throws {
        let rig = MainDeadlineRig(), reveal = Self.reveal(rig, onServer: true)
        let row = Row(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = row
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        try #require(window.screen != nil, "the window is on no screen: nothing animates")
        Self.install(reveal, in: row)
        var landings: [Bool] = []
        reveal.onLanding = { landings.append($0) }
        try Self.withMotion {
            reveal.setEngaged(true)
            reveal.setEngaged(false)
            rig.fireAndRun()
            reveal.setEngaged(true)
        }
        #expect(landings == [false, false], "the changes taken over did not land at once, not finished: \(landings)")
        #expect(row.band.clipsToBounds)
        #expect(await SplitRenderMotionTests.until { landings.count == 3 }, "the reopen did not land in 5 s")
        #expect(landings == [false, false, true])
        #expect(!reveal.inFlight)
        #expect(!row.band.clipsToBounds, "the landed band still clips its items (focus rings)")
        #expect(!row.band.keepsItemsFullSize)
    }
}
