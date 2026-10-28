import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import CmuxNextWakeups
import Testing

/// The tests that need Core Animation to run a spring: a real window on a real display (a window on no
/// screen does not animate). They run with the pane bench (CMUX_PANE_BENCH=1,
/// scripts/measure/split-spring.sh --suite=pane-bench); the others run under a plain `swift test`.
nonisolated private let onScreenBench = ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"

/// A screen switch on the render server (`motion.renderServer` on): the
/// switch puts both screens at their rest frames and opacities in its turn, and Core Animation shows the
/// new screen sliding and fading in and the old one out, with the rings and dims of their panes. No CPU
/// spring steps, the window's MotionClock never runs for it, the switch lands once (where the old screen
/// hides), a switch back mid-flight goes on from what shows, and a switch without animation, parking, a
/// third screen, a layout pass and a CPU frame under Reduce Motion each stop the springs they take. With
/// the switch off, or a page in its own window, the CPU steps it as before.
@MainActor
@Suite(.serialized)
struct ScreenSwitchRenderMotionTests {
    final class Panes: LayoutPaneContentProvider {
        var contents: [PaneID: NSView] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let content = NSView()
            content.wantsLayer = true
            contents[pane] = content
            return content
        }
    }

    /// Screens `ids` (the first shown), one pane `<id>-p1` each, in a 1200 x 800 window; ``show(_:)`` switches.
    final class Screens {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Every layout motion start (true) and end (false) the root announced.
        var motion: [Bool] = []
        private var observation: LayoutOverlaySyncObservation?
        private var landing: CheckedContinuation<Bool, Never>?

        /// `reduceMotion` pins Reduce Motion for this root; nil follows `Motion` (the process-wide override).
        init(renderServer: Bool, reduceMotion: Bool? = false, ids: [ScreenID] = ["a", "b"]) {
            model = LayoutModel(screens: ids.map { LayoutScreen(id: $0, name: $0.rawValue, layout: .splits(.leaf(PaneID(rawValue: "\($0.rawValue)-p1")))) },
                                activeScreenID: ids[0], focusedPane: PaneID(rawValue: "\(ids[0].rawValue)-p1"))
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer },
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            observation = root.observeLayoutMotion { [weak self] moving in
                guard let self else { return }
                motion.append(moving)
                if !moving { resumeLanding(true) }
            }
        }

        func view(_ screen: ScreenID) throws -> ScreenContentView { try #require(root.screenViews[screen]) }

        func layer(_ screen: ScreenID) throws -> CALayer { try #require(view(screen).layer) }

        /// The ring and dim view of screen `screen`'s pane.
        func chrome(_ screen: ScreenID) throws -> PaneOverlayView {
            try #require(root.context.hosts[PaneID(rawValue: "\(screen.rawValue)-p1")]).chrome
        }

        func chromeLayer(_ screen: ScreenID) throws -> CALayer { try #require(chrome(screen).layer) }

        /// How far a screen slides in or out: 18 % of the width.
        var shift: CGFloat { root.bounds.width * 0.18 }

        func show(_ screen: ScreenID) {
            model.selectScreen(screen)
            root.syncWithModel()
        }

        /// Waits for the layout motion to end; false after `timeout`.
        func landed(timeout: Duration = .seconds(5)) async -> Bool {
            if motion.last == false { return true }
            return await withCheckedContinuation { continuation in
                landing = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeLanding(false)
                }
            }
        }

        private func resumeLanding(_ landed: Bool) {
            landing?.resume(returning: landed)
            landing = nil
        }

        /// The switch is over: nothing in flight, no spring on any screen or its ring and dim, the layout
        /// motion started and ended once, `shown` shows at rest and every other screen is hidden.
        func expectLanded(showing shown: ScreenID, _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(!root.screenSwitch.isInFlight, "\(comment): a switch is still in flight", sourceLocation: sourceLocation)
            #expect(!root.driver.isRunning, "\(comment): the window's MotionClock runs", sourceLocation: sourceLocation)
            #expect(motion == [true, false], "\(comment): layout motion \(motion)", sourceLocation: sourceLocation)
            for id in root.screenViews.keys {
                #expect(try !ScreenSwitchRenderMotionTests.hasRenderSprings(layer(id)), "\(comment): \(id) keeps springs",
                        sourceLocation: sourceLocation)
                #expect(try !ScreenSwitchRenderMotionTests.hasRenderSprings(chromeLayer(id)), "\(comment): \(id)'s ring keeps springs",
                        sourceLocation: sourceLocation)
                let view = try view(id)
                if id == shown {
                    #expect(!view.isHidden && view.frame == root.bounds && view.alphaValue == 1, "\(comment): \(id) is not at rest",
                            sourceLocation: sourceLocation)
                } else {
                    #expect(view.isHidden, "\(comment): \(id) did not hide", sourceLocation: sourceLocation)
                }
            }
        }

        func close() {
            observation = nil
            window.orderOut(nil)
            window.close()
        }
    }

    /// Movement animates for the panes gate (Reduce Motion pinned to `reduceMotion`).
    static func withMotion<T>(reduceMotion: Bool = false, _ body: () async throws -> T) async throws -> T {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesMovement != reduceMotion, "panes movement does not follow Reduce Motion on this host")
        return try await body()
    }

    /// Stops the render server's clock under `root`: springs show the time ``seek(_:to:)`` sets.
    static func freeze(_ root: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.speed = 0
        root.timeOffset = 0
        CATransaction.commit()
        CATransaction.flush()
    }

    static func seek(_ root: CALayer, to time: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.timeOffset = time
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The left edge and opacity `layer` presents `time` seconds into the frozen clock.
    static func presented(_ layer: CALayer, at time: CFTimeInterval, root: CALayer) throws -> (x: CGFloat, opacity: CGFloat) {
        seek(root, to: time)
        let shown = try #require(layer.presentation(), "no presentation layer after a commit")
        return (shown.frame.minX, CGFloat(shown.opacity))
    }

    /// Seconds a spring from rest takes to cover `progress` of its way (cmux-motion's closed form, which the
    /// render-server spring matches within 0.25 pt, RenderSpringParityTests).
    static func time(toProgress progress: Double, _ spring: SpringParameters) -> Double {
        var time = 0.0
        while time < 5, 1 - SpringValue.solve(displacement: 1, velocity: 0, time: time, parameters: spring).displacement < progress {
            time += 0.0005
        }
        return time
    }

    /// The key paths of the render-server springs on `layer` (keys `cmux.renderSpring.<serial>.<keyPath>`).
    static func springKeyPaths(_ layer: CALayer) -> [String] {
        let prefix = "cmux.renderSpring."
        return (layer.animationKeys() ?? []).compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let rest = key.dropFirst(prefix.count)
            guard let dot = rest.firstIndex(of: "."), Int(rest[..<dot]) != nil else { return nil }
            return String(rest[rest.index(after: dot)...])
        }
    }

    static func hasRenderSprings(_ layer: CALayer) -> Bool { !springKeyPaths(layer).isEmpty }

    static func hasPositionSprings(_ layer: CALayer) -> Bool { springKeyPaths(layer).contains { $0.hasPrefix("position") } }

    // MARK: On the render server (on-screen bench)

    @Test(.enabled(if: onScreenBench)) func aSwitchRestsInItsTurnAndSlidesOnTheRenderServer() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(screens.root.layer)
            Self.freeze(clock)
            screens.show("b")
            let root = screens.root
            #expect(!root.screensStepping, "a CPU screen spring is left to step")
            #expect(!root.driver.isRunning, "the switch asked the window's MotionClock for frames")
            #expect(screens.motion == [true], "the layout motion starts in the switch's turn")
            #expect(root.screenSwitch.screens == ["a", "b"], "\(root.screenSwitch.screens)")
            #expect(root.screenSwitch.pending.isEmpty, "the switch's turn did not start its springs")
            let a = try screens.view("a"), b = try screens.view("b")
            #expect(b.frame == root.bounds && b.alphaValue == 1 && !b.isHidden, "b is not at rest: \(b.frame) \(b.alphaValue)")
            #expect(a.frame.minX == -screens.shift && a.alphaValue == 0, "a is not at rest: \(a.frame) \(a.alphaValue)")
            #expect(!a.isHidden, "a hid before its fade showed")
            // From where each showed, half way along the screen spring, to rest.
            let half = Self.time(toProgress: 0.5, Motion.panes.spring(.screen))
            let bStart = try Self.presented(screens.layer("b"), at: 0, root: clock)
            #expect(abs(bStart.x - screens.shift) <= 0.5 && bStart.opacity <= 0.01, "b starts at \(bStart)")
            let aStart = try Self.presented(screens.layer("a"), at: 0, root: clock)
            #expect(abs(aStart.x) <= 0.5 && aStart.opacity >= 0.99, "a starts at \(aStart)")
            let bHalf = try Self.presented(screens.layer("b"), at: half, root: clock)
            #expect(abs(bHalf.x - screens.shift / 2) <= 1 && abs(bHalf.opacity - 0.5) <= 0.02, "b half way shows \(bHalf)")
            let aHalf = try Self.presented(screens.layer("a"), at: half, root: clock)
            #expect(abs(aHalf.x + screens.shift / 2) <= 1 && abs(aHalf.opacity - 0.5) <= 0.02, "a half way shows \(aHalf)")
        }
    }

    /// The overlay plane draws the rings and dims above the screens: each one slides and fades with its
    /// screen, not at its rest from the switch's turn (the CPU path re-placed them every frame).
    @Test(.enabled(if: onScreenBench)) func theRingsAndDimsSlideAndFadeWithTheirScreen() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(screens.root.layer)
            Self.freeze(clock)
            screens.show("b")
            let spring = Motion.panes.spring(.screen)
            for screen: ScreenID in ["a", "b"] {
                let chrome = try screens.chrome(screen)
                try #require(chrome.superview === screens.root.overlayPlane, "\(screen)'s ring is not in the overlay plane")
                let ringLayer = try screens.chromeLayer(screen), screenLayer = try screens.layer(screen)
                let restGap = ringLayer.frame.minX - screenLayer.frame.minX
                let hostAlpha = try #require(screens.root.context.hosts[PaneID(rawValue: "\(screen.rawValue)-p1")]).alphaValue
                for progress in [0.25, 0.5, 0.75] {
                    let time = Self.time(toProgress: progress, spring)
                    let ring = try Self.presented(ringLayer, at: time, root: clock)
                    let shown = try Self.presented(screenLayer, at: time, root: clock)
                    #expect(abs(ring.x - shown.x - restGap) <= 0.5,
                            "\(screen)'s ring is \(ring.x - shown.x - restGap) pt off its pane at \(progress)")
                    #expect(abs(ring.opacity - hostAlpha * shown.opacity) <= 0.02,
                            "\(screen)'s ring shows opacity \(ring.opacity), its screen \(shown.opacity), at \(progress)")
                }
            }
        }
    }

    @Test(.enabled(if: onScreenBench)) func aSwitchBackMidFlightGoesOnFromWhatShows() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(screens.root.layer)
            Self.freeze(clock)
            screens.show("b")
            let half = Self.time(toProgress: 0.5, Motion.panes.spring(.screen))
            let dt = 1.0 / 4000
            let ids: [ScreenID] = ["a", "b"]
            /// Where each screen shows at `half` and how fast it moves there (points per second).
            @MainActor func sample() throws -> [(x: CGFloat, opacity: CGFloat, slope: CGFloat)] {
                try ids.map { id in
                    let later = try Self.presented(screens.layer(id), at: half + dt, root: clock)
                    let now = try Self.presented(screens.layer(id), at: half, root: clock)
                    return (now.x, now.opacity, (later.x - now.x) / CGFloat(dt))
                }
            }
            // The switch back lands at `half` on the frozen clock: its springs begin there.
            let before = try sample()
            screens.show("a")
            #expect(!screens.root.screensStepping, "the switch back left a CPU spring to step")
            #expect(!screens.root.driver.isRunning, "the switch back asked for frames")
            let after = try sample()
            for (index, screen) in ids.enumerated() {
                #expect(abs(before[index].x - after[index].x) <= 0.5 && abs(before[index].opacity - after[index].opacity) <= 0.01,
                        "\(screen) jumped from \(before[index]) to \(after[index]) when the switch turned back")
                let slope = before[index].slope
                #expect(abs(after[index].slope - slope) <= max(40, abs(slope) * 0.05),
                        "\(screen) moved at \(slope) pt/s and at \(after[index].slope) pt/s after the switch back")
            }
            let a = try screens.view("a")
            #expect(a.frame == screens.root.bounds && a.alphaValue == 1, "a is not at rest after the switch back")
        }
    }

    @Test(.enabled(if: onScreenBench)) func theSwitchLandsOnce() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            let syncs = screens.root.overlaySyncs
            screens.show("b")
            #expect(screens.root.overlaySyncs - syncs == 1, "the switch's turn synced the overlay \(screens.root.overlaySyncs - syncs) times")
            #expect(await screens.landed(), "the switch did not land in 5 s")
            #expect(screens.root.overlaySyncs - syncs == 2, "the overlay synced \(screens.root.overlaySyncs - syncs - 1) times after the turn")
            try screens.expectLanded(showing: "b", "the landing")
        }
    }

    /// Reduce Motion turned on with a switch in flight: the springs run out on the render server (Chrome's
    /// running compositor animations do the same) and the switch lands once; a frame the CPU steps for other
    /// motion meanwhile stops them at once.
    @Test(.enabled(if: onScreenBench)) func reduceMotionMidFlightRunsOutOrStopsOnTheNextCPUFrame() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true, reduceMotion: nil)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.show("b")
            try #require(screens.root.screenSwitch.isInFlight && !screens.root.driver.isRunning)
            Motion.reduceMotionOverride = true
            #expect(await screens.landed(), "the switch did not land in 5 s after Reduce Motion turned on")
            try screens.expectLanded(showing: "b", "Reduce Motion mid-flight, springs run out")

            let stepped = Screens(renderServer: true)
            defer { stepped.close() }
            Motion.reduceMotionOverride = false
            stepped.show("b")
            try #require(stepped.root.screenSwitch.isInFlight)
            stepped.root.context.reduceMotionOverride = true
            #expect(!stepped.root.advanceFrame(1.0 / 120), "the frame under Reduce Motion asked for more")
            try stepped.expectLanded(showing: "b", "Reduce Motion mid-flight, a CPU frame")
        }
    }

    @Test(.enabled(if: onScreenBench)) func aSwitchWithoutAnimationMidFlightLandsInItsTurn() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.show("b")
            try #require(screens.root.screenSwitch.isInFlight)
            screens.root.context.reduceMotionOverride = true
            screens.show("a")
            try screens.expectLanded(showing: "a", "a switch without animation")
        }
    }

    @Test(.enabled(if: onScreenBench)) func parkingMidFlightLandsTheSwitch() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.show("b")
            try #require(screens.root.screenSwitch.isInFlight)
            screens.root.isHidden = true
            #expect(!screens.root.isLive, "hiding the root did not park it")
            try screens.expectLanded(showing: "b", "parking")
        }
    }

    @Test(.enabled(if: onScreenBench)) func aThirdScreenMidFlightStopsTheFirst() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true, ids: ["a", "b", "c"])
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.show("b")
            try #require(screens.root.screenSwitch.screens == ["a", "b"])
            screens.show("c")
            #expect(screens.root.screenSwitch.screens == ["b", "c"], "\(screens.root.screenSwitch.screens)")
            #expect(try screens.view("a").isHidden, "a, snapped out by the third screen, still shows")
            #expect(try !Self.hasRenderSprings(screens.layer("a")), "a keeps the first switch's springs")
            #expect(try !Self.hasRenderSprings(screens.chromeLayer("a")), "a's ring keeps the first switch's springs")
            #expect(screens.motion == [true], "layout motion \(screens.motion)")
            #expect(await screens.landed(), "the switch did not land in 5 s")
            try screens.expectLanded(showing: "c", "the third screen")
        }
    }

    /// A layout pass (a window resize) places the screens at rest: the screen it moves takes its
    /// position from its springs and its ring's; its fade goes on, and the switch still lands once.
    @Test(.enabled(if: onScreenBench)) func aLayoutPassMidFlightTakesThePositionItMoves() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.show("b")
            try #require(screens.root.screenSwitch.isInFlight)
            screens.window.setContentSize(NSSize(width: 1000, height: 800))
            screens.root.layoutSubtreeIfNeeded()
            let a = try screens.view("a")
            #expect(a.frame.origin == screens.root.bounds.origin, "the layout pass did not place a at its rest: \(a.frame)")
            #expect(try !Self.hasPositionSprings(screens.layer("a")), "a's position springs survive the pass that placed it")
            #expect(try !Self.hasPositionSprings(screens.chromeLayer("a")), "a's ring's position springs survive the pass")
            #expect(screens.root.screenSwitch.isInFlight && !a.isHidden, "the pass ended a's fade")
            #expect(await screens.landed(), "the switch did not land in 5 s")
            try screens.expectLanded(showing: "b", "the layout pass")
        }
    }

    /// A page in its own child window follows the model frames, not a spring: a switch to its screen stays
    /// on the CPU step until tasks 051 to 053 remove that window.
    @Test(.enabled(if: onScreenBench)) func aPageInItsOwnWindowKeepsTheSwitchOnTheCPUStep() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.root.driver.isManual = true
            try #require(screens.panes.contents["b-p1"]).addSubview(ZoomRenderMotionTests.Page(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
            screens.show("b")
            #expect(screens.root.screensStepping, "the switch to a page window's screen does not step on the CPU")
            #expect(!screens.root.screenSwitch.isInFlight, "the switch to a page window's screen is on the render server")
            #expect(try !Self.hasRenderSprings(screens.layer("b")), "b has render-server springs")
            for _ in 0..<480 where !screens.root.advanceFrame(1.0 / 120) { break }
            #expect(!screens.root.screensStepping, "the CPU switch did not land")
            #expect(try screens.view("a").isHidden, "the old screen did not hide when the CPU switch landed")
        }
    }

    // MARK: No animation needed (plain swift test)

    @Test func reduceMotionLandsInTheSwitchsTurn() async throws {
        try await Self.withMotion(reduceMotion: true) {
            let screens = Screens(renderServer: true, reduceMotion: true)
            defer { screens.close() }
            screens.show("b")
            #expect(!screens.root.screensStepping)
            #expect(!screens.root.screenSwitch.isInFlight)
            let a = try screens.view("a"), b = try screens.view("b")
            #expect(a.isHidden, "the old screen did not hide in the switch's turn")
            #expect(b.frame == screens.root.bounds)
            for screen: ScreenID in ["a", "b"] {
                let layer = try screens.layer(screen)
                #expect(!Self.hasRenderSprings(layer), "\(screen) animates under Reduce Motion")
            }
        }
    }

    @Test func offTheSwitchStepsOnTheCPUAsBefore() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: false)
            defer { screens.close() }
            screens.root.driver.isManual = true
            screens.show("b")
            #expect(screens.root.screensStepping, "the switch does not spring on the CPU")
            #expect(!screens.root.screenSwitch.isInFlight)
            for screen: ScreenID in ["a", "b"] {
                let layer = try screens.layer(screen)
                #expect(!Self.hasRenderSprings(layer), "\(screen) has render-server springs with the switch off")
            }
            #expect(screens.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
            for _ in 0..<480 where !screens.root.advanceFrame(1.0 / 120) { break }
            #expect(!screens.root.screensStepping, "the CPU switch did not land")
            let a = try screens.view("a")
            #expect(a.isHidden, "the old screen did not hide when the CPU switch landed")
        }
    }
}
