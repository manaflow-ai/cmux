import AppKit
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch window is built behind its picture slice by slice (tab strips, the focused pane, each
/// other visible pane, then live), one afterFirstFrame post each, so no main turn builds the whole window; the picture
/// leaves region by region, each pane's part at that pane's own first meaningful content, all of it at the bound; no
/// area ever shows neither the picture nor its drawn content (a blank region). Fake regions: a fake window and fake
/// panes behind the real phase, regions and reveal; the startup scheduler's queue is run by hand, one post per step.
@MainActor @Suite(.serialized) struct LaunchWindowBuildTests {
    /// The startup scheduler's afterFirstFrame queue, run by hand one post at a time.
    final class Slices {
        private(set) var queued: [(name: String, work: @MainActor @Sendable () -> Void)] = []
        private(set) var ran: [String] = []

        var post: LaunchWindowBuild.Post {
            { [self] name, work in queued.append(("\(name)", work)) }
        }

        var queuedNames: [String] { queued.map(\.name) }

        @discardableResult
        func runNext() -> Bool {
            guard !queued.isEmpty else { return false }
            let next = queued.removeFirst()
            ran.append(next.name)
            next.work()
            return true
        }

        func runAll() { while runNext() {} }
    }

    /// A pane whose content draws when the test says (its terminal's first frame, its page's first contentful paint).
    final class Pane: LaunchWindowPane {
        let area: CGRect
        unowned let slices: Slices
        /// The posts that showed it, by index in ``Slices/ran``.
        private(set) var shownIn: [Int] = []
        private(set) var hasDrawn = false
        private var waiters: [@MainActor () -> Void] = []

        init(_ area: CGRect, slices: Slices) {
            self.area = area
            self.slices = slices
        }

        var center: CGPoint { CGPoint(x: area.midX, y: area.midY) }

        func showForLaunch() { shownIn.append(slices.ran.count - 1) }

        func whenLaunchContentDrawn(_ drawn: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
            if hasDrawn {
                drawn()
                return nil
            }
            waiters.append(drawn)
            return { [weak self] in self?.waiters.removeAll() }
        }

        func draw() {
            hasDrawn = true
            let waiting = waiters
            waiters = []
            for drawn in waiting { drawn() }
        }

        func launchArea(in picture: NSView) -> CGRect { area }
    }

    final class Window: LaunchBuiltWindow {
        let panes: [Pane]
        unowned let slices: Slices
        private(set) var mountedIn: [Int] = []
        private(set) var wentLive = 0

        init(panes: [Pane], slices: Slices) {
            self.panes = panes
            self.slices = slices
        }

        func mountLaunchStrips() -> [any LaunchWindowPane] {
            mountedIn.append(slices.ran.count - 1)
            return panes
        }

        func goLive() { wentLive += 1 }
    }

    /// The launch window behind its picture: the phase showed the picture, the controller's root is adopted under it.
    final class Rig {
        static let size = NSSize(width: 1100, height: 720)
        let slices: Slices
        let rig: MainDeadlineRig
        let phase: LaunchPicturePhase
        let reveal: LaunchReveal
        let shell: NSWindow
        let regions: LaunchPictureRegions
        let window: Window
        let build: LaunchWindowBuild

        /// - Parameter areas: The panes' areas, the focused one first.
        init(areas: [CGRect], onScreen: Bool = false) throws {
            let slices = Slices(), rig = MainDeadlineRig(), reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
            let shell = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled], backing: .buffered, defer: false)
            shell.isReleasedWhenClosed = false
            if onScreen { shell.orderFrontRegardless() }
            let phase = LaunchPicturePhase(deadlines: rig.deadlines) { _ in }
            phase.show(try Self.image(), in: shell, scope: ThemeScope(level: .room), present: {}, startup: nil) {}
            // The controller's root takes the window, as `WindowController` installs it; the picture goes over it.
            let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
            shell.contentView = root
            let regions = try #require(phase.adopt(root: root, reveal: reveal))
            let window = Window(panes: areas.map { Pane($0, slices: slices) }, slices: slices)
            let build = LaunchWindowBuild(window: window, regions: regions, reveal: reveal, post: slices.post) {}
            (self.slices, self.rig, self.phase, self.reveal, self.shell) = (slices, rig, phase, reveal, shell)
            (self.regions, self.window, self.build) = (regions, window, build)
            build.start()
        }

        var panes: [Pane] { window.panes }

        /// The window's title row, outside every pane: the rest of the picture.
        static let titleRow = CGPoint(x: 550, y: 710)

        /// Each pane shows the picture or its own drawn content, never neither.
        func noBlankRegion() -> Bool {
            panes.allSatisfy { regions.covers($0.center) || $0.hasDrawn }
        }

        static func image() throws -> CGImage {
            let width = Int(size.width) * 2, height = Int(size.height) * 2
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }

        func tearDown() {
            shell.orderOut(nil)
            shell.close()
        }
    }

    static let left = CGRect(x: 0, y: 0, width: 550, height: 690)
    static let right = CGRect(x: 550, y: 0, width: 550, height: 690)
    static let bottom = CGRect(x: 0, y: 0, width: 1100, height: 300)

    // MARK: Slices

    @Test func eachSliceIsItsOwnPostInTheSpecsOrder() throws {
        let launch = try Rig(areas: [Self.left, Self.right, Self.bottom])
        defer { launch.tearDown() }
        #expect(launch.slices.queuedNames == ["\(LaunchWindowBuild.tabStrips)"], "nothing of the window is built before the first post")
        #expect(launch.window.mountedIn.isEmpty)

        launch.slices.runNext()
        #expect(launch.window.mountedIn == [0], "the tab strips are their own slice")
        #expect(launch.panes.allSatisfy { $0.shownIn.isEmpty }, "the strips' slice shows no pane's content")
        #expect(launch.slices.queuedNames == ["\(LaunchWindowBuild.focusedPane)", "\(LaunchWindowBuild.visiblePane)",
                                              "\(LaunchWindowBuild.visiblePane)", "\(LaunchWindowBuild.live)"])

        launch.slices.runAll()
        #expect(launch.panes.map(\.shownIn) == [[1], [2], [3]], "one pane per post, the focused pane first, each shown once")
        #expect(launch.window.wentLive == 1 && launch.build.isDone, "the window goes live in the last post")
        #expect(launch.slices.ran.count == 5)
    }

    @Test func noPostBuildsEveryPane() throws {
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        var turns: [Int] = []
        while !launch.slices.queued.isEmpty {
            let before = launch.panes.reduce(0) { $0 + $1.shownIn.count }
            launch.slices.runNext()
            turns.append(launch.panes.reduce(0) { $0 + $1.shownIn.count } - before)
        }
        #expect(turns.allSatisfy { $0 <= 1 }, "a post showed more than one pane: \(turns)")
        #expect(turns.reduce(0, +) == 2)
    }

    // MARK: Regions

    @Test func eachPanesPartLeavesAtItsOwnFirstContent() throws {
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        launch.slices.runAll()
        // The first content anywhere marks the app-wide regions (LaunchSettle, PaneController).
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        let (left, right) = (launch.panes[0], launch.panes[1])
        #expect(launch.regions.covers(left.center) && launch.regions.covers(right.center), "no pane has drawn")
        #expect(launch.noBlankRegion())

        right.draw()
        #expect(launch.regions.covers(left.center), "a split's other pane keeps its part until it draws")
        #expect(!launch.regions.covers(right.center), "the pane that drew is live")
        #expect(launch.regions.covers(Rig.titleRow), "the rest waits for the last part")
        #expect(launch.noBlankRegion())

        left.draw()
        #expect(launch.regions.isFinished && launch.phase.picture == nil, "the last part takes the rest and the picture with it")
        #expect(launch.noBlankRegion())
    }

    /// A focused page installs its view, and the app marks the pane region, before the page paints: its part stays
    /// until the page's first contentful paint.
    @Test func aPagePaneKeepsItsPartUntilItsFirstContentfulPaint() throws {
        let launch = try Rig(areas: [Self.left])
        defer { launch.tearDown() }
        launch.slices.runNext()
        launch.slices.runNext() // the focused page shows; PaneController marks the pane region at install
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        let page = launch.panes[0]
        #expect(launch.regions.covers(page.center), "the page's part left before the page painted")
        page.draw()
        #expect(!launch.regions.covers(page.center))
    }

    @Test func aPartNeverUncoversAHeldStripOrContent() throws {
        let launch = try Rig(areas: [Self.left])
        defer { launch.tearDown() }
        launch.slices.runAll()
        let pane = launch.panes[0]
        pane.draw()
        #expect(launch.regions.covers(pane.center), "the strip and content are still held clear")
        launch.reveal.markReady(.tabs)
        #expect(launch.regions.covers(pane.center))
        launch.reveal.markReady(.pane)
        #expect(!launch.regions.covers(pane.center))
    }

    @Test func theBoundTakesEveryPartDownAndShowsEveryRegion() throws {
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        launch.slices.runAll()
        #expect(launch.rig.hasArmedWake, "the bound is armed once the picture is over the live root")
        launch.rig.fireAndRun()
        #expect(launch.regions.isFinished && launch.phase.picture == nil, "the bound left a part up")
        #expect(LaunchRegion.allCases.allSatisfy(launch.reveal.isReady), "the bound left a region held")
    }

    @Test func theRestStaysUntilNoPartComesLater() throws {
        let launch = try Rig(areas: [Self.left])
        defer { launch.tearDown() }
        launch.slices.runNext()
        launch.slices.runNext()
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        launch.panes[0].draw()
        #expect(launch.regions.covers(Rig.titleRow), "the rest left before the build was over")
        launch.slices.runAll()
        #expect(launch.regions.isFinished)
    }

    // MARK: Motion

    /// A part fades out through the panes' gate; with animations off it goes in one frame and the picture with it.
    @Test(.enabled("a window with no screen draws no frame") { await MainActor.run { !NSScreen.screens.isEmpty } },
          .enabled("animation speed is off on this host") { await MainActor.run { Motion.speed != .off } })
    func aPartFadesThroughTheMotionGateAndLeavesInOneFrameWithAnimationsOff() throws {
        Motion.reduceMotionOverride = false
        let enabled = DesignSettings.shared.animationsEnabled
        DesignSettings.shared.animationsEnabled = true
        defer {
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.animationsEnabled = enabled
        }
        let launch = try Rig(areas: [Self.left, Self.right], onScreen: true)
        defer { launch.tearDown() }
        try #require(Motion.panes.duration(.fadeOut) > 0, "the panes' fades are off on this host")
        launch.slices.runAll()
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        let (left, right) = (launch.panes[0], launch.panes[1])
        let leftLayer = try #require(launch.regions.layer(of: LaunchPictureRegions.Part(index: 0)))
        let rightLayer = try #require(launch.regions.layer(of: LaunchPictureRegions.Part(index: 1)))
        left.draw()
        #expect(leftLayer.animation(forKey: "opacity") != nil, "the part left with no fade")
        #expect(leftLayer.opacity == 0)

        DesignSettings.shared.animationsEnabled = false
        right.draw()
        #expect(rightLayer.animation(forKey: "opacity") == nil, "a part faded with animations off")
        #expect(rightLayer.opacity == 0)
        #expect(launch.phase.picture == nil, "with animations off the picture leaves in the frame of its last part")
    }

    /// A region's held views show at once under the picture: the picture's part is the one fade. A region with no
    /// picture over it still fades in.
    @Test(.enabled("a window with no screen draws no frame") { await MainActor.run { !NSScreen.screens.isEmpty } },
          .enabled("animation speed is off on this host") { await MainActor.run { Motion.speed != .off } })
    func aCoveredRegionDoesNotFadeASecondTime() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let (covered, uncovered) = (NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 300)), NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300)))
        for view in [covered, uncovered] {
            view.wantsLayer = true
            host.addSubview(view)
        }
        window.contentView = host
        let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
        reveal.hold(covered, until: .pane)
        reveal.hold(uncovered, until: .sidebar)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        try #require(covered.layer?.presentation() != nil && uncovered.layer?.presentation() != nil, "the window drew no frame")

        reveal.coverBegan([.pane])
        reveal.markReady(.pane)
        #expect(covered.alphaValue == 1)
        #expect(covered.layer?.animation(forKey: "opacity") == nil, "a region under the picture faded in a second time")
        reveal.markReady(.sidebar)
        #expect(uncovered.layer?.animation(forKey: "opacity") != nil, "a region with no picture over it showed with no fade")
    }
}
