import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Clicks on the launch picture and the picture phase's edges. The picture is the window's
/// `LaunchPictureView` over the live root, masked by `LaunchPictureRegions`. A click where a part
/// still shows the picture is held and raises the window's build (`LaunchWindowBuild.raise`) to the next frame; when
/// the part leaves at its region's first content the click goes again at the same point, exactly once, to the live
/// view under it. It is dropped when what the window shows or its size changed meanwhile, past the hold, or at the
/// bound. The picture's edges reach the key router's stand-in buffer: `launch_picture_shown` begins it, the picture
/// leaving ends it.
@MainActor @Suite(.serialized)
struct LaunchPictureClickTests {
    typealias Slices = LaunchWindowBuildTests.Slices
    typealias Window = LaunchWindowBuildTests.Window
    typealias Pane = LaunchWindowBuildTests.Pane

    /// What the input asked of the app.
    @MainActor final class Record {
        var stamp = "ws-1"
        var sent: [NSEvent.EventType] = []
        var elapsed = Duration.zero
        let start = ContinuousClock.now
    }

    /// The launch window behind its picture, as `LaunchSnapshotWindow` wires it: the input begins at the picture, the
    /// controller's root is adopted under it, one pane is built slice by slice.
    @MainActor final class Launch {
        static let size = NSSize(width: 1100, height: 720)
        static let paneArea = CGRect(x: 0, y: 0, width: 550, height: 690)
        static let inPane = CGPoint(x: 275, y: 345)
        /// The window's title row, outside every pane: the rest of the picture.
        static let titleRow = CGPoint(x: 550, y: 710)

        let slices: Slices
        let rig: MainDeadlineRig
        let reveal: LaunchReveal
        let record: Record
        let keys: LaunchPictureKeys
        let shell: NSWindow
        let phase: LaunchPicturePhase
        let picture: LaunchPictureView
        let regions: LaunchPictureRegions
        let window: Window
        let build: LaunchWindowBuild
        let input: LaunchPictureInput

        init(holdsClicks: Bool = true) throws {
            let slices = Slices(), rig = MainDeadlineRig(), reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
            let record = Record(), keys = LaunchPictureKeys { _, _ in false }
            let shell = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .resizable], backing: .buffered,
                                 defer: false)
            shell.isReleasedWhenClosed = false
            let input = LaunchPictureInput(window: "w1", shell: shell, keys: keys, reveal: reveal, mainWork: rig.work,
                                           resend: { record.sent.append($0.type) }, now: { record.start + record.elapsed }) { record.stamp }
            let phase = LaunchPicturePhase(deadlines: rig.deadlines) { _ in }
            phase.show(try LaunchWindowBuildTests.Rig.image(), in: shell, scope: ThemeScope(level: .room), present: {}, startup: nil) {}
            phase.whenRemoved { input.finish() }
            // The controller's root takes the window, as `WindowController` installs it; the picture goes over it.
            let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
            shell.contentView = root
            let picture = try #require(phase.picture)
            let regions = try #require(phase.adopt(root: root, reveal: reveal))
            if holdsClicks { input.holdClicks(on: picture, regions: regions) }
            let window = Window(panes: [Pane(Self.paneArea, slices: slices)], slices: slices)
            let build = LaunchWindowBuild(window: window, regions: regions, reveal: reveal, post: slices.post,
                                          urgent: { name, work in rig.work.post(.userBlocking, owner: "\(name)", work) }) {}
            input.build = build
            (self.slices, self.rig, self.reveal, self.record, self.keys) = (slices, rig, reveal, record, keys)
            (self.shell, self.phase, self.picture, self.regions) = (shell, phase, picture, regions)
            (self.window, self.build, self.input) = (window, build, input)
            build.start()
        }

        var pane: Pane { window.panes[0] }

        /// Whether a click at `point` (the root's coordinates) waits on the picture.
        func pictureTakesClick(at point: CGPoint) -> Bool { picture.hitTest(point) != nil }

        func press(at point: CGPoint) throws {
            let view = try #require(picture.hitTest(point), "the picture did not take the click at \(point)")
            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: point))
        }

        func release(at point: CGPoint) throws {
            picture.mouseUp(with: try Self.mouse(.leftMouseUp, at: point))
        }

        func click(at point: CGPoint) throws {
            try press(at: point)
            try release(at: point)
        }

        /// The pane's content drew and the app-wide regions show: its part leaves.
        func paneGoesLive() {
            slices.runAll()
            reveal.markReady(.tabs)
            reveal.markReady(.pane)
            pane.draw()
        }

        static func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func tearDown() {
            shell.orderOut(nil)
            shell.close()
        }
    }

    /// A click on the pane's part waits and raises the build to the next frame, never in its own turn; when the pane
    /// has its first content its mouse-down and mouse-up go again exactly once, in order, and later clicks reach the
    /// live view (the part is gone) while the rest is still a picture.
    @Test func aClickOnAPartNotLiveIsSentAgainOnceWhenItGoesLive() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext() // the tab strips: the pane's part is over its area
        try launch.click(at: Launch.inPane)
        #expect(launch.pane.shownIn.isEmpty, "the click built the pane in its own turn")
        #expect(launch.record.sent.isEmpty, "a click went to a view that is not built")
        #expect(launch.input.heldClicks == 1)
        launch.rig.frame()
        #expect(launch.pane.shownIn.count == 1, "the click did not raise the focused pane to the next frame")
        launch.reveal.markReady(.tabs)
        launch.reveal.markReady(.pane)
        #expect(launch.record.sent.isEmpty, "the pane has not drawn")
        launch.pane.draw()
        #expect(launch.record.sent == [.leftMouseDown, .leftMouseUp])
        #expect(launch.input.heldClicks == 0)
        #expect(!launch.pictureTakesClick(at: Launch.inPane), "the pane's part still takes clicks after it left")
        #expect(launch.pictureTakesClick(at: Launch.titleRow), "the rest is still a picture")
        launch.slices.runAll()
        #expect(launch.pane.shownIn.count == 1, "the focused pane's slice ran again after the raise")
    }

    /// A click on the rest of the picture (the title row) goes again when the last part takes the rest with it.
    @Test func aClickOnTheRestGoesWithTheLastPart() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext()
        try launch.click(at: Launch.titleRow)
        launch.paneGoesLive()
        #expect(launch.regions.isFinished)
        #expect(launch.record.sent == [.leftMouseDown, .leftMouseUp])
    }

    /// The part went live between the press and the release: the release follows the press at once.
    @Test func aReleaseAfterThePartWentLiveFollowsItsPress() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext()
        try launch.press(at: Launch.inPane)
        launch.paneGoesLive()
        #expect(launch.record.sent == [.leftMouseDown])
        try launch.release(at: Launch.inPane)
        #expect(launch.record.sent == [.leftMouseDown, .leftMouseUp])
    }

    /// The window shows another workspace now (a chord switched it): the click meant the old one and is dropped.
    @Test func aClickWhoseWindowsModelChangedIsDropped() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext()
        try launch.click(at: Launch.inPane)
        launch.record.stamp = "ws-2"
        launch.paneGoesLive()
        #expect(launch.record.sent.isEmpty)
    }

    /// The window changed size (a resize, a full-screen toggle): the click's point is another place now.
    @Test func aClickWhoseWindowResizedIsDropped() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext()
        try launch.click(at: Launch.inPane)
        launch.shell.setContentSize(NSSize(width: 1200, height: 720))
        try #require(launch.picture.bounds.width == 1200, "the picture did not follow the window's size")
        launch.paneGoesLive()
        #expect(launch.record.sent.isEmpty)
    }

    /// A part live after the 2 s hold: the click is dropped.
    @Test func aClickOlderThanTheHoldIsDropped() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext()
        try launch.click(at: Launch.inPane)
        launch.record.elapsed = LaunchPictureInput.clickLimit + .milliseconds(100)
        launch.paneGoesLive()
        #expect(launch.record.sent.isEmpty)
    }

    /// The bound takes the picture down with no content: a held click is dropped, never sent to a region with none.
    @Test func theBoundDropsTheHeldClicks() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.slices.runNext()
        try launch.click(at: Launch.inPane)
        try launch.click(at: Launch.titleRow)
        launch.rig.fireAndRun()
        #expect(launch.regions.isFinished && launch.phase.picture == nil)
        #expect(launch.record.sent.isEmpty && launch.input.heldClicks == 0)
        #expect(!launch.pictureTakesClick(at: Launch.inPane), "the picture still takes clicks after it left")
    }

    /// Without the input holding clicks the picture takes none, as before (060).
    @Test func withoutHeldClicksThePictureTakesNone() throws {
        let launch = try Launch(holdsClicks: false)
        defer { launch.tearDown() }
        launch.slices.runNext()
        #expect(!launch.pictureTakesClick(at: Launch.inPane) && !launch.pictureTakesClick(at: Launch.titleRow))
    }

    // MARK: The picture phase's edges

    /// `launch_picture_shown` begins the key router's picture phase for the window (its mode turns on and a key for
    /// its terminal waits and raises the build to the next frame), and the picture leaving ends it in its own turn.
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
        let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60))
        let rig = MainDeadlineRig(), slices = Slices()
        let input = LaunchPictureInput(window: controller.state.id, shell: shell, keys: keys, reveal: reveal, mainWork: rig.work) { "edge-workspace" }
        #expect(keys.showsPicture(window: controller.state.id), "launch_picture_shown did not begin the window's key buffer")
        #expect(router.modes.contains(.launchPicture))

        let picture = LaunchPictureView(image: try LaunchWindowBuildTests.Rig.image(), scale: 2)
        let regions = LaunchPictureRegions(picture: picture) {}
        let window = Window(panes: [], slices: slices)
        let build = LaunchWindowBuild(window: window, regions: regions, reveal: reveal, post: slices.post,
                                      urgent: { name, work in rig.work.post(.userBlocking, owner: "\(name)", work) }) {}
        input.build = build

        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 50_000,
                                                  windowNumber: shell.windowNumber, context: nil, characters: "l",
                                                  charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
        #expect(router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: shell) })
        let target = LaunchPictureKeys.Target(window: controller.state.id, pane: "edge-pane", tab: "edge-tab")
        #expect(keys.isHolding(target))
        #expect(window.mountedIn.isEmpty, "the key built the window in its own turn")
        rig.frame()
        #expect(window.mountedIn.count == 1, "the key did not raise the window's build to the next frame")

        // The picture left (`LaunchPicturePhase.whenRemoved` runs `finish`).
        input.finish()
        #expect(keys.showsPicture(window: controller.state.id), "the buffer ended inside the picture's own turn")
        rig.frame()
        #expect(!keys.showsPicture(window: controller.state.id), "the picture left but the window's key buffer did not end")
        #expect(keys.isHolding(target), "the key for a terminal still not live was dropped with the picture")
    }
}
