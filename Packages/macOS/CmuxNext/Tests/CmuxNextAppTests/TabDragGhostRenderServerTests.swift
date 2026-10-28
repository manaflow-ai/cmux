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

/// The tab drag ghost on the render server (`motion.renderServer` on).
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

    /// The source window shows every rect inside its frame in front (no other window over it).
    static func holds(_ window: NSWindow) -> (CGRect) -> Bool { { window.frame.contains($0) } }

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

    /// A flight's room holds every place its root still flies from and what showed when it started.
    @Test func aFlightHoldsBothPlacesUntilItLands() {
        var flight = TabDragGhostFlight()
        let panel = CGRect(x: 1000, y: 500, width: 400, height: 300)
        #expect(flight.widened(panel) == panel, "a ghost at rest needs no room")
        flight.add(shift: CGPoint(x: -120, y: 60), drawn: CGRect(x: 32, y: 240, width: 160, height: 28))
        #expect(flight.widened(panel) == CGRect(x: 880, y: 500, width: 520, height: 360))
        flight.add(shift: CGPoint(x: 40, y: -20), drawn: CGRect(x: 26, y: 70, width: 300, height: 200))
        #expect(flight.offsets == CGRect(x: -120, y: -20, width: 160, height: 80))
        let tab = CGRect(x: 32, y: 240, width: 160, height: 28)
        let rest = TabDragGhostRest(layout: TabDragGhostLayout(motion: Self.motion(at: CGPoint(x: 1032, y: 740)), cardSize: CGSize(width: 300, height: 200),
                                                               inset: 6, grabOffset: CGPoint(x: 20, y: 14), tabSize: Self.tabSize),
                                    opacity: 1, rootSize: CGSize(width: 400, height: 300), pad: 32, inset: 6, onGlass: false, shadowAlpha: 0.2)
        #expect(rest.tab == tab)
        let drawn = tab.union(CGRect(x: 26, y: 70, width: 300, height: 200)).offsetBy(dx: rest.origin.x, dy: rest.origin.y)
        #expect(flight.reach(of: rest) == CGRect(x: drawn.minX - 120, y: drawn.minY - 20, width: drawn.width + 160, height: drawn.height + 80))
    }

    @Test func insideTheSourceWindowTheGhostFollowsThePointerWithNoWindowCall() throws {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, holds: Self.holds(window))
        #expect(ghost.isInSourceWindow, "the ghost is a view of the source window's overlay")
        #expect(!ghost.panel.isVisible, "the drag panel stays off screen inside the source window")
        let overlay = try #require(ghost.root.window)
        #expect(overlay !== ghost.panel)
        let overlayFrame = overlay.frame, panelFrame = ghost.panel.frame
        let start = ghost.root.frame.origin
        for step in 1...20 {
            motion.setTarget(Self.tab(at: CGPoint(x: 500 + CGFloat(step) * 4, y: 600 - CGFloat(step) * 2)), cardness: 0, jump: false)
            ghost.present(motion, token: .track, holds: Self.holds(window))
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
        ghost.present(motion, token: .track, holds: Self.holds(window))
        #expect(ghost.isInSourceWindow)

        motion.setTarget(Self.tab(at: CGPoint(x: 1600, y: 600)), cardness: 0, jump: false)
        ghost.present(motion, token: .track, holds: nil)
        #expect(!ghost.isInSourceWindow)
        #expect(ghost.panel.isVisible && ghost.root.window === ghost.panel, "outside the window the panel holds the ghost")

        motion.setTarget(Self.tab(at: CGPoint(x: 500, y: 600)), cardness: 0, jump: false)
        ghost.present(motion, token: .track, holds: Self.holds(window))
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
        ghost.present(motion, token: .track, holds: Self.holds(window))
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
        ghost.present(motion, token: .track, holds: Self.holds(window))
        try #require(Motion.canAnimate(in: ghost.root), "the window is on no screen or its display sleeps: nothing animates")
        try #require(Motion.tabs.animatesMovement, "tabs movement is off in this host's settings")
        let start = ghost.root.frame.origin

        motion.setTarget(Self.tab(at: CGPoint(x: 560, y: 640)), cardness: 0, jump: true)
        ghost.present(motion, token: .track, holds: Self.holds(window))
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
        ghost.present(motion, token: .track, holds: Self.holds(window))
        var rests = 0
        ghost.onRest = { rests += 1 }
        motion.setTarget(Self.tab(at: CGPoint(x: 420, y: 650)), cardness: 0, opacity: 0, jump: true)
        ghost.present(motion, token: .settle, holds: nil, landing: true)
        #expect(rests == 1, "the landing settled \(rests) times")
        #expect(ghost.isInSourceWindow, "the flight stays in the host it started in")
    }

    /// A ghost the session closed (its landing ended) shows nothing again: a preview or a daemon echo
    /// that arrives late never puts it back on screen.
    @Test func aClosedGhostNeverShowsAgain() {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, holds: Self.holds(window))
        ghost.close()
        #expect(ghost.root.window == nil && !ghost.panel.isVisible)

        motion.setTarget(Self.tab(at: CGPoint(x: 520, y: 600)), cardness: 1, jump: true)
        ghost.present(motion, token: .appear, holds: Self.holds(window))
        ghost.present(motion, token: .appear, holds: nil)
        #expect(ghost.root.window == nil, "the closed ghost went back into the source window's overlay")
        #expect(!ghost.panel.isVisible, "the closed ghost's panel came back")
    }

    /// The common reorder: a tab slot of a top-row strip, its top on the window's top edge. The
    /// ghost stays in the overlay and the pointer moves cost no window call.
    @Test func aTopRowStripSlotFollowsThePointerWithNoWindowCall() async throws {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        let top = window.frame.maxY - Self.tabSize.height
        var motion = Self.motion(at: CGPoint(x: 400, y: top))
        ghost.present(motion, token: .track, holds: Self.holds(window))
        #expect(ghost.isInSourceWindow, "a top-row slot left the source window's overlay")

        let stats = RenderStats()
        try #require(stats.arm(), "this build has no render counters")
        let counting = await stats.ready()
        stats.reset()
        for step in 1...20 {
            motion.setTarget(Self.tab(at: CGPoint(x: 400 + CGFloat(step) * 6, y: top)), cardness: 0, jump: false)
            ghost.present(motion, token: .track, holds: Self.holds(window))
        }
        #expect(ghost.isInSourceWindow)
        let ghostWindows: [AnyClass] = [NSPanel.self, OverlayHostPanel.self]
        let calls = stats.owners().filter { owner in ghostWindows.contains { RenderStats.classKey($0) == owner.key } }
            .reduce(0) { $0 + $1.totals[.windowCalls] }
        #expect(counting, "the render counters did not install")
        #expect(calls == 0, "the pointer moves made \(calls) window calls")
        // Every original IMP back before the next test arms its own counters.
        stats.disarm()
        _ = await stats.ready()
    }

    /// A window in front of part of the source window: the card would draw under it in the overlay,
    /// so the panel (above every window) shows it.
    @Test func aWindowInFrontOfTheCardSendsTheGhostToThePanel() {
        let source = CGRect(x: 200, y: 200, width: 1100, height: 720)
        let other = CGRect(x: 700, y: 100, width: 600, height: 400)
        let ordered = [
            TabDragWindowPick.Candidate(frame: CGRect(x: 600, y: 300, width: 320, height: 240), controllerID: nil, occludes: false),
            TabDragWindowPick.Candidate(frame: other, controllerID: "other"),
            TabDragWindowPick.Candidate(frame: source, controllerID: nil, occludes: false),
            TabDragWindowPick.Candidate(frame: source, controllerID: "source"),
        ]
        #expect(TabDragWindowPick.isFrontmost("source", over: CGRect(x: 300, y: 600, width: 300, height: 200), in: ordered))
        #expect(!TabDragWindowPick.isFrontmost("source", over: CGRect(x: 600, y: 450, width: 300, height: 200), in: ordered),
                "the other window covers the card's corner")
        #expect(!TabDragWindowPick.isFrontmost("source", over: CGRect(x: 1200, y: 600, width: 300, height: 200), in: ordered),
                "the card leaves the source window")
        #expect(!TabDragWindowPick.isFrontmost("other", over: CGRect(x: 800, y: 150, width: 100, height: 100),
                                              in: [TabDragWindowPick.Candidate(frame: other, controllerID: "other", isVisible: false)]))

        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        let covered = CGRect(x: 600, y: 500, width: 400, height: 300)
        let holds: (CGRect) -> Bool = { window.frame.contains($0) && !covered.intersects($0) }
        var motion = Self.motion(at: CGPoint(x: 300, y: 800))
        ghost.present(motion, token: .track, holds: holds)
        #expect(ghost.isInSourceWindow)
        motion.setTarget(Self.tab(at: CGPoint(x: 560, y: 640)), cardness: 0, jump: false)
        ghost.present(motion, token: .track, holds: holds)
        #expect(!ghost.isInSourceWindow && ghost.panel.isVisible, "the overlay held a ghost another window covers")
    }

    /// A jump that also leaves the source window: the panel holds both places, so the flight from
    /// where the ghost showed is never clipped; the next follow keeps that room until it lands.
    @Test func aJumpThatChangesTheHostKeepsItsFlightInThePanel() throws {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        Motion.reduceMotionOverride = false
        defer {
            Motion.reduceMotionOverride = nil
            ghost.close()
            window.close()
        }
        var motion = Self.motion(at: CGPoint(x: 500, y: 600))
        ghost.present(motion, token: .track, holds: Self.holds(window))
        try #require(ghost.isInSourceWindow)
        try #require(Motion.canAnimate(in: ghost.root), "the window is on no screen or its display sleeps: nothing animates")
        try #require(Motion.tabs.animatesMovement, "tabs movement is off in this host's settings")
        let from = try #require(ghost.shown).origin

        motion.setTarget(Self.tab(at: CGPoint(x: 700, y: 980)), cardness: 1, jump: true)
        ghost.present(motion, token: .track, holds: Self.holds(window))
        let to = try #require(ghost.shown).origin
        #expect(!ghost.isInSourceWindow && ghost.panel.isVisible)
        let both = CGRect(origin: to, size: ghost.panelSize).union(CGRect(origin: from, size: ghost.panelSize))
        #expect(ghost.panel.frame.contains(both), "the panel \(ghost.panel.frame) clips the flight \(both)")
        #expect(ghost.root.frame.origin == CGPoint(x: to.x - ghost.panel.frame.minX, y: to.y - ghost.panel.frame.minY))

        motion.setTarget(Self.tab(at: CGPoint(x: 704, y: 982)), cardness: 1, jump: false)
        ghost.present(motion, token: .track, holds: nil)
        #expect(ghost.panel.frame.width >= both.width && ghost.panel.frame.height >= both.height, "a follow dropped the flight's room")
    }

    /// The card's shape and edge come from its clip, which springs; the glass in it stays the size
    /// of the root, so nothing relays the glass out per frame.
    @Test func theCardKeepsItsEdgeAndTheGlassNeverResizes() throws {
        let window = Self.sourceWindow()
        let ghost = Self.ghost(in: window)
        defer {
            ghost.close()
            window.close()
        }
        let motion = TabDragGhostMotion(rect: Self.tab(at: CGPoint(x: 300, y: 800)), cardness: 1)
        ghost.present(motion, token: .track, holds: Self.holds(window))
        let rest = try #require(ghost.shown)
        let clip = try #require(ghost.root.subviews.first)
        let glass = try #require(clip.subviews.first)
        #expect(clip.frame == rest.glass)
        #expect(clip.layer?.masksToBounds == true && (clip.layer?.cornerRadius ?? 0) > 0)
        #expect((clip.layer?.borderWidth ?? 0) > 0, "the card has no edge")
        #expect(glass.frame.size == ghost.root.bounds.size)
        #expect(glass.convert(glass.bounds, to: ghost.root).origin == .zero, "the glass moved on the root")
    }

    /// The drag session with `motion.renderServer` on: its frame client only auto-scrolls (a pointer
    /// event away from the edge bands does not wake it) and a cancel's landing ends the drag. (The
    /// window is not the manager's, so the session sees no
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
        #expect(drag.link?.isActive == false, "a pointer event woke the frame clock with no auto-scroll or dwell")
        #expect(drag.ghost.root.window != nil, "the ghost shows nowhere")
        session.finish(commit: false)
        #expect(session.landing == nil, "the landing did not end the drag")
        #expect(drag.link == nil)
    }
}
