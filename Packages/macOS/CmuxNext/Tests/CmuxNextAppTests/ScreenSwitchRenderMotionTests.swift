import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A screen switch on the render server (chrome-parity p03-rendering-030, `motion.renderServer` on): the
/// switch puts both screens at their rest frames and opacities in its turn, and Core Animation shows the
/// new screen sliding and fading in and the old one out. No CPU spring steps, the window's MotionClock
/// never runs for it, the switch lands once (where the old screen hides), a switch back mid-flight goes on
/// from what shows, Reduce Motion lands in the turn, and with the switch off the CPU steps it as before.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct ScreenSwitchRenderMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView {
            let content = NSView()
            content.wantsLayer = true
            return content
        }
    }

    /// Screens `a` (shown) and `b`, one pane each, in a 1200 x 800 window; ``show(_:)`` switches.
    final class Screens {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Every layout motion start (true) and end (false) the root announced.
        var motion: [Bool] = []
        private var observation: LayoutOverlaySyncObservation?
        private var landing: CheckedContinuation<Bool, Never>?

        init(renderServer: Bool, reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "a", name: "a", layout: .splits(.leaf("a-p1"))),
                                          LayoutScreen(id: "b", name: "b", layout: .splits(.leaf("b-p1")))],
                                activeScreenID: "a", focusedPane: "a-p1")
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer })
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

    static func hasRenderSprings(_ layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { $0.hasPrefix("cmux.renderSpring.") }
    }

    @Test func aSwitchRestsInItsTurnAndSlidesOnTheRenderServer() async throws {
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

    @Test func aSwitchBackMidFlightGoesOnFromWhatShows() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(screens.root.layer)
            Self.freeze(clock)
            screens.show("b")
            let half = Self.time(toProgress: 0.5, Motion.panes.spring(.screen))
            let ids: [ScreenID] = ["a", "b"]
            let before = try ids.map { try Self.presented(screens.layer($0), at: half, root: clock) }
            screens.show("a")
            #expect(!screens.root.screensStepping, "the switch back left a CPU spring to step")
            #expect(!screens.root.driver.isRunning, "the switch back asked for frames")
            let after = try ids.map { try Self.presented(screens.layer($0), at: half, root: clock) }
            for (index, screen) in ids.enumerated() {
                #expect(abs(before[index].x - after[index].x) <= 0.5 && abs(before[index].opacity - after[index].opacity) <= 0.01,
                        "\(screen) jumped from \(before[index]) to \(after[index]) when the switch turned back")
            }
            let a = try screens.view("a")
            #expect(a.frame == screens.root.bounds && a.alphaValue == 1, "a is not at rest after the switch back")
        }
    }

    @Test func theSwitchLandsOnce() async throws {
        try await Self.withMotion {
            let screens = Screens(renderServer: true)
            defer { screens.close() }
            try #require(screens.window.screen != nil, "the window is on no screen: nothing animates")
            screens.show("b")
            #expect(await screens.landed(), "the switch did not land in 5 s")
            #expect(screens.motion == [true, false], "layout motion \(screens.motion)")
            #expect(!screens.root.screenSwitch.isInFlight)
            #expect(!screens.root.driver.isRunning, "the landing asked for frames")
            #expect(try screens.view("a").isHidden, "the old screen did not hide when the switch landed")
            #expect(try !screens.view("b").isHidden)
            for screen: ScreenID in ["a", "b"] {
                #expect(try !Self.hasRenderSprings(screens.layer(screen)), "\(screen) keeps springs after the landing")
            }
        }
    }

    @Test func reduceMotionLandsInTheSwitchsTurn() async throws {
        try await Self.withMotion(reduceMotion: true) {
            let screens = Screens(renderServer: true, reduceMotion: true)
            defer { screens.close() }
            screens.show("b")
            #expect(!screens.root.screensStepping)
            #expect(!screens.root.screenSwitch.isInFlight)
            #expect(try screens.view("a").isHidden, "the old screen did not hide in the switch's turn")
            #expect(try screens.view("b").frame == screens.root.bounds)
            for screen: ScreenID in ["a", "b"] {
                #expect(try !Self.hasRenderSprings(screens.layer(screen)), "\(screen) animates under Reduce Motion")
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
                #expect(try !Self.hasRenderSprings(screens.layer(screen)), "\(screen) has render-server springs with the switch off")
            }
            #expect(screens.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
            for _ in 0..<480 where !screens.root.advanceFrame(1.0 / 120) { break }
            #expect(!screens.root.screensStepping, "the CPU switch did not land")
            #expect(try screens.view("a").isHidden, "the old screen did not hide when the CPU switch landed")
        }
    }
}
