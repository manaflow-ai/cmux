import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Clicks on the launch picture and the picture phase's edges (p08-startup-061). The picture is the window's
/// `LaunchPictureCover` (p08-startup-060), the view the launch puts over the live root. A click on a part still over
/// the window is held and raises the window's build; when the part leaves at its regions' first content the click
/// goes again at the same point, exactly once, to the live view under it. It is dropped when what the window shows
/// changed meanwhile, at the bound, or when a resize removes the picture. The picture's edges reach the key router's
/// stand-in buffer: `launch_picture_shown` begins it, the picture leaving ends it.
@MainActor @Suite(.serialized)
struct LaunchPictureClickTests {
    @MainActor final class Launch {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        let pane = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 280))
        let rig = MainDeadlineRig()
        let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
        var cover: LaunchPictureCover!
        let record = Record()

        /// What the cover asked of the window.
        @MainActor final class Record {
            var stamp = "ws-1"
            var raised: [Set<LaunchRegion>] = []
            var sent: [NSEvent.EventType] = []
            var finished = 0
            var elapsed = Duration.zero
            let start = ContinuousClock.now
        }

        var stamp: String {
            get { record.stamp }
            set { record.stamp = newValue }
        }
        var elapsed: Duration {
            get { record.elapsed }
            set { record.elapsed = newValue }
        }
        var raised: [Set<LaunchRegion>] { record.raised }
        var sent: [NSEvent.EventType] { record.sent }
        var finished: Int { record.finished }

        init(clicks: Bool = true) throws {
            for view in [sidebar, pane] {
                view.wantsLayer = true
                host.addSubview(view)
            }
            reveal.hold(sidebar, until: .sidebar)
            reveal.hold(pane, until: .pane)
            let image = try #require(Self.image(width: 400, height: 300))
            let record = record
            let held = LaunchPictureCover.Clicks(stamp: { record.stamp }, raise: { record.raised.append($0) },
                                                 resend: { record.sent.append($0.type) },
                                                 now: { record.start + record.elapsed })
            cover = LaunchPictureCover(image: image, over: host, parts: [
                .init(until: [.sidebar]) { [sidebar] in sidebar.frame },
                .init(until: [.tabs, .pane]) { [pane] in pane.frame },
            ], reveal: reveal, deadlines: rig.deadlines, clicks: clicks ? held : nil, onFinish: { record.finished += 1 })
        }

        static func image(width: Int, height: Int) -> CGImage? {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return context?.makeImage()
        }

        /// The view a click at `point` (host coordinates) reaches: the topmost part that takes it, else nil.
        func hit(_ point: CGPoint) -> NSView? {
            for view in host.subviews.reversed() {
                if let hit = view.hitTest(point) { return hit }
            }
            return nil
        }

        func click(at point: CGPoint) throws {
            let view = try #require(hit(point), "no part of the picture took the click at \(point)")
            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: point))
            view.mouseUp(with: try Self.mouse(.leftMouseUp, at: point))
        }

        static func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
    }

    private static let inPane = CGPoint(x: 250, y: 150)
    private static let inSidebar = CGPoint(x: 50, y: 150)

    /// A click on the pane's part waits and raises the build; when the pane has its first content, its mouse-down
    /// and mouse-up go again exactly once, in order, and later clicks reach the live view (the part is gone).
    @Test func aClickOnAPartNotLiveIsSentAgainOnceWhenItGoesLive() throws {
        let launch = try Launch()
        try launch.click(at: Self.inPane)
        #expect(launch.raised == [[.tabs, .pane]], "the click raised \(launch.raised)")
        #expect(launch.sent.isEmpty, "a click went to a view that is not built")
        #expect(launch.cover.heldClicks == 1)
        launch.elapsed = .milliseconds(400)
        launch.reveal.markReady(.tabs)
        #expect(launch.sent.isEmpty, "tabs alone are not the pane's first content")
        launch.reveal.markReady(.pane)
        #expect(launch.sent == [.leftMouseDown, .leftMouseUp])
        #expect(launch.cover.heldClicks == 0)
        #expect(launch.hit(Self.inPane) == nil, "the pane's part still takes clicks after it left")
        #expect(launch.hit(Self.inSidebar) != nil, "the sidebar is still a picture")
    }

    /// The part went live between the press and the release: the release follows the press at once.
    @Test func aReleaseAfterThePartWentLiveFollowsItsPress() throws {
        let launch = try Launch()
        let view = try #require(launch.hit(Self.inPane))
        view.mouseDown(with: try Launch.mouse(.leftMouseDown, at: Self.inPane))
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        #expect(launch.sent == [.leftMouseDown])
        view.mouseUp(with: try Launch.mouse(.leftMouseUp, at: Self.inPane))
        #expect(launch.sent == [.leftMouseDown, .leftMouseUp])
    }

    /// The window shows another workspace now (a chord switched it): the click meant the old one and is dropped.
    @Test func aClickWhoseWindowsModelChangedIsDropped() throws {
        let launch = try Launch()
        try launch.click(at: Self.inPane)
        launch.stamp = "ws-2"
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        #expect(launch.sent.isEmpty)
    }

    /// A part live after the 2 s hold: the click is dropped.
    @Test func aClickOlderThanTheHoldIsDropped() throws {
        let launch = try Launch()
        try launch.click(at: Self.inSidebar)
        launch.elapsed = LaunchPictureCover.clickLimit + .milliseconds(100)
        launch.reveal.markReady(.sidebar)
        #expect(launch.sent.isEmpty)
    }

    /// The bound takes the picture down with no content: a held click is dropped, never sent to a region with none.
    @Test func theBoundDropsTheHeldClicks() throws {
        let launch = try Launch()
        try launch.click(at: Self.inPane)
        launch.rig.advance(by: LaunchPictureCover.bound)
        launch.rig.fireAndRun()
        #expect(launch.cover.isFinished)
        #expect(launch.sent.isEmpty && launch.cover.heldClicks == 0)
        #expect(launch.finished == 1)
    }

    /// A resize (a full-screen toggle resizes too) or a live resize removes the picture at once, with the clicks it
    /// held: their points no longer mean the same place.
    @Test func aResizeRemovesThePictureAtOnceAndDropsItsClicks() throws {
        let launch = try Launch()
        try launch.click(at: Self.inPane)
        launch.host.setFrameSize(NSSize(width: 500, height: 300))
        #expect(!launch.cover.layout())
        #expect(launch.cover.isFinished && launch.finished == 1)
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        #expect(launch.sent.isEmpty)

        let live = try Launch()
        try live.click(at: Self.inSidebar)
        try #require(live.hit(Self.inSidebar)).viewWillStartLiveResize()
        #expect(live.cover.isFinished && live.finished == 1, "a live resize kept the picture")
        #expect(live.cover.heldClicks == 0)
    }

    /// Without click handling the picture takes no click, as before (060).
    @Test func withoutClicksThePictureTakesNone() throws {
        let launch = try Launch(clicks: false)
        #expect(launch.hit(Self.inPane) == nil && launch.hit(Self.inSidebar) == nil)
    }

    // MARK: The picture phase's edges

    /// `launch_picture_shown` begins the key router's picture phase for the window (its mode turns on and a key for
    /// its terminal waits and raises the build), and the picture leaving ends it.
    @Test func thePicturesEdgesBeginAndEndTheKeyBuffer() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["edge-workspace"]))
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "edge-workspace", panes: [
            .init(id: "edge-pane", tabs: [.init(id: "edge-tab", kind: .terminal)], selected: "edge-tab"),
        ])))
        controller.focus.send(.focusPane("edge-pane", source: .keyboard))
        let router = services.keyRouter, keys = router.launchPictureKeys
        var raises = 0
        let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
        let rig = MainDeadlineRig()
        let built = Count()
        let input = LaunchPictureInput(window: controller.state.id, shell: shell, keys: keys, reveal: reveal, mainWork: rig.work,
                                       pastFirstFrame: {
                                           raises += 1
                                           return true
                                       }, build: { built.value += 1 }) { "edge-workspace" }
        #expect(keys.showsPicture(window: controller.state.id), "launch_picture_shown did not begin the window's key buffer")
        #expect(router.modes.contains(.launchPicture))

        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 50_000,
                                                  windowNumber: shell.windowNumber, context: nil, characters: "l",
                                                  charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
        #expect(router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: shell) })
        let target = LaunchPictureKeys.Target(window: controller.state.id, pane: "edge-pane", tab: "edge-tab")
        #expect(keys.isHolding(target))
        #expect(raises == 1, "the key did not raise the window's build")
        #expect(built.value == 0, "the key built the window in its own turn")
        rig.frame()
        #expect(built.value == 1, "the raised build did not run in the next frame")

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(Launch.image(width: 400, height: 300))
        let cover = LaunchPictureCover(image: image, over: host, parts: [], reveal: reveal, deadlines: rig.deadlines,
                                       clicks: input.clicks, onFinish: input.finish)
        for region in LaunchRegion.allCases { reveal.markReady(region) }
        #expect(cover.isFinished)
        #expect(keys.showsPicture(window: controller.state.id), "the buffer ended inside the picture's own turn")
        rig.frame()
        #expect(!keys.showsPicture(window: controller.state.id), "the picture left but the window's key buffer did not end")
        #expect(keys.isHolding(target), "the key for a terminal still not live was dropped with the picture")
    }

    @MainActor final class Count {
        var value = 0
    }
}
