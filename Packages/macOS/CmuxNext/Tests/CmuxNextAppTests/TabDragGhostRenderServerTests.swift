import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextLayout
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextWakeups
import QuartzCore
import Testing

/// The tab drag ghost on the render server (chrome-parity p03-rendering-035, `motion.renderServer` on).
/// Inside its source window the ghost is a view in that window's overlay, moved per pointer event with
/// no window call; the drag panel shows it only outside the window. A jump is one `RenderSpring` group,
/// the release's flight closes the ghost when it lands, and no `TabDrag.ghost` frame client steps it.
@MainActor @Suite(.serialized) struct TabDragGhostRenderServerTests {
    static let tabSize = CGSize(width: 160, height: 28)

    /// An ordered-in window at (200, 200), 1100 x 720 (the ghost fits only in a window on screen).
    static func sourceWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1100, height: 720), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    static func ghost(in window: NSWindow?) -> TabDragGhostPanel {
        TabDragGhostPanel(tabImage: nil, tabSize: tabSize, grabOffset: CGPoint(x: 20, y: 14), aspect: 0.6, scale: 2,
                          onGlass: false, sourceWindow: window, rendersOnServer: true)
    }

    /// An inline tab (no card) at `origin`.
    static func motion(at origin: CGPoint) -> TabDragGhostMotion {
        TabDragGhostMotion(rect: CGRect(origin: origin, size: tabSize), cardness: 0)
    }

    static func tab(at origin: CGPoint) -> CGRect { CGRect(origin: origin, size: tabSize) }

    /// The rest folds the scale into the layer frames about the grabbed point (no transform to spring),
    /// and only a jump counts as one.
    @Test func theRestScalesAboutTheGrabbedPointAndOnlyJumpsCount() {
        let tab = CGRect(x: 400, y: 500, width: 160, height: 28)
        var motion = TabDragGhostMotion(rect: tab, cardness: 0)
        motion.setTarget(tab, cardness: 0, scale: 0.5, jump: false)
        #expect(motion.jumpCount == 0)
        let layout = TabDragGhostLayout(motion: motion.rest, cardSize: CGSize(width: 300, height: 200), inset: 6,
                                        grabOffset: CGPoint(x: 20, y: 14), tabSize: tab.size)
        let rest = TabDragGhostRest(layout: layout, opacity: 1, rootSize: CGSize(width: 400, height: 300), pad: 32, inset: 6,
                                    onGlass: false, shadowAlpha: 0.2)
        #expect(rest.origin == CGPoint(x: 368, y: 260))
        // The grabbed point (420, 514) on screen is (52, 254) in the root; the half-size tab keeps it.
        #expect(rest.tab == CGRect(x: 42, y: 247, width: 80, height: 14))
        #expect(rest.tabShadow == 0.2 && rest.thumbOpacity == 0 && rest.glassOpacity == 0)

        motion.setTarget(tab.offsetBy(dx: 30, dy: 0), cardness: 1, jump: true, velocity: CGVector(dx: 500, dy: -200))
        #expect(motion.jumpCount == 1 && motion.jumpVelocity == CGVector(dx: 500, dy: -200))
        #expect(motion.rest.presentedRect == tab.offsetBy(dx: 30, dy: 0), "the rest is the target")
    }

    @Test func insideTheSourceWindowTheGhostFollowsThePointerWithNoWindowCall() throws {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, inSourceWindow: true)
        #expect(ghost.isInSourceWindow, "the ghost is a view of the source window's overlay")
        #expect(!ghost.panel.isVisible, "the drag panel stays off screen inside the source window")
        let overlay = try #require(ghost.root.window)
        #expect(overlay !== ghost.panel)
        let overlayFrame = overlay.frame, panelFrame = ghost.panel.frame
        let start = ghost.root.frame.origin
        for step in 1...20 {
            motion.setTarget(Self.tab(at: CGPoint(x: 500 + CGFloat(step) * 4, y: 600 - CGFloat(step) * 2)), cardness: 0, jump: false)
            ghost.present(motion, token: .track, inSourceWindow: true)
        }
        #expect(overlay.frame == overlayFrame && ghost.panel.frame == panelFrame, "a window moved while the ghost followed the pointer")
        #expect(!ghost.panel.isVisible)
        #expect(ghost.root.frame.origin == CGPoint(x: start.x + 80, y: start.y - 40), "the ghost did not follow the pointer")
        #expect(ghost.root.layer?.animationKeys()?.isEmpty != false, "a pointer move that is no jump adds no spring")
    }

    @Test func outsideTheSourceWindowThePanelShowsTheGhostAndInsideItLeaves() {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, inSourceWindow: true)
        #expect(ghost.isInSourceWindow)

        motion.setTarget(Self.tab(at: CGPoint(x: 1600, y: 600)), cardness: 0, jump: false)
        ghost.present(motion, token: .track, inSourceWindow: false)
        #expect(!ghost.isInSourceWindow)
        #expect(ghost.panel.isVisible && ghost.root.window === ghost.panel, "outside the window the panel holds the ghost")

        motion.setTarget(Self.tab(at: CGPoint(x: 500, y: 600)), cardness: 0, jump: false)
        ghost.present(motion, token: .track, inSourceWindow: true)
        #expect(ghost.isInSourceWindow && !ghost.panel.isVisible, "back in the window the panel left the screen")
    }

    /// A card that would cross the window's edge shows in the panel, never clipped by the window.
    @Test func aGhostThatDoesNotFitTheSourceWindowShowsInThePanel() {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        let motion = TabDragGhostMotion(rect: Self.tab(at: CGPoint(x: window.frame.maxX - 60, y: 600)), cardness: 1)
        ghost.present(motion, token: .track, inSourceWindow: true)
        #expect(!ghost.isInSourceWindow)
        #expect(ghost.panel.isVisible)
    }

    /// A jump (an inline slot, the card folding) springs the root from where it showed on the render
    /// server: the model is at rest at once and the layer carries additive springs.
    @Test func aJumpIsOneRenderServerSpringFromWhereTheGhostShowed() throws {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        Motion.reduceMotionOverride = false
        defer {
            Motion.reduceMotionOverride = nil
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, inSourceWindow: true)
        try #require(Motion.canAnimate(in: ghost.root), "the window is on no screen or its display sleeps: nothing animates")
        try #require(Motion.tabs.animatesMovement, "tabs movement is off in this host's settings")
        let start = ghost.root.frame.origin

        motion.setTarget(Self.tab(at: CGPoint(x: 560, y: 640)), cardness: 0, jump: true)
        ghost.present(motion, token: .track, inSourceWindow: true)
        #expect(ghost.root.frame.origin == CGPoint(x: start.x + 60, y: start.y + 40), "the model is not at rest at once")
        let keys = ghost.root.layer?.animationKeys() ?? []
        #expect(keys.contains { $0.hasPrefix("cmux.renderSpring.") && $0.hasSuffix(".position.x") })
        #expect(keys.contains { $0.hasPrefix("cmux.renderSpring.") && $0.hasSuffix(".position.y") })
    }

    /// The release's flight closes the ghost once, when it lands (here at once: the display sleeps).
    @Test func theLandingClosesTheGhostOnce() {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        DisplaySleep.asleepOverride = true
        defer {
            DisplaySleep.asleepOverride = nil
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, inSourceWindow: true)
        var rests = 0
        ghost.onRest = { rests += 1 }
        motion.setTarget(Self.tab(at: CGPoint(x: 420, y: 650)), cardness: 0, opacity: 0, jump: true)
        ghost.present(motion, token: .settle, inSourceWindow: false, landing: true)
        #expect(rests == 1, "the landing settled \(rests) times")
        #expect(ghost.isInSourceWindow, "the flight stays in the host it started in")
    }

    /// The drag session with `motion.renderServer` on: its frame client only auto-scrolls and a
    /// cancel's landing ends the drag. (The window is not the manager's, so the session sees no
    /// window under the pointer: the placement is the tests above.)
    @Test func theSessionStepsNoGhostFrames() throws {
        let key = LayoutTunables.motionRenderServer.key
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([LayoutTunables.motionRenderServer.descriptor])
        try #require(TunableStore.shared.set(key, .bool(true)) == .bool(true), "the toggle takes the override")
        DisplaySleep.asleepOverride = true
        defer {
            TunableStore.shared.set(key, nil)
            DisplaySleep.asleepOverride = nil
        }
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1"),
        ])
        tree.personal = PersonalState(workspaces: [
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0),
        ])
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"ghost-render","workspace_key":"k1"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ["k1"]
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let session = services.dragSession
        let handoff = SidebarDragHandoff(payload: .workspaces([WorkspaceID("k1")]), workspaceIDs: [WorkspaceID("k1")],
                                         rowScreenFrame: CGRect(x: 300, y: 300, width: 220, height: 28),
                                         grabOffset: CGPoint(x: 20, y: 14), screenPoint: CGPoint(x: 320, y: 314),
                                         image: nil, imageOnGlass: false)
        #expect(session.beginWorkspaces(handoff, from: controller))
        let drag = try #require(session.drag)
        #expect(drag.ghost.rendersOnServer)
        #expect(drag.link?.owner == "TabDrag.autoscroll", "a frame client steps the ghost")
        #expect(drag.ghost.root.window != nil, "the ghost shows nowhere")
        session.finish(commit: false)
        #expect(session.landing == nil, "the landing did not end the drag")
        #expect(drag.link == nil)
    }
}
