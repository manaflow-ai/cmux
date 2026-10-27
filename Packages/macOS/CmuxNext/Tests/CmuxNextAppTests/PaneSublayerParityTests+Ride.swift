import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// What rides with the chrome besides its frames: the overlay syncs once, at the spring's start; a glowing
/// attention ring's outline follows its spring; the exclusion mask a dock cuts keeps its cutout
/// where the dock rests and covers the whole moving chrome; and the start converts through a zoomed canvas.
extension PaneSublayerParityTests {
    /// Cmd-D places every ring once, in the key's turn (`LayoutViewContext.overlaySyncNow`): the sync the turn
    /// scheduled finds nothing stale, and nothing syncs while the spring runs.
    @Test func cmdDSyncsTheOverlayOnceAtItsStart() async throws {
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            Render.freeze(clock)
            let before = split.root.overlaySyncs
            split.split()
            let inTurn = split.root.overlaySyncs - before
            #expect(inTurn == 1, "Cmd-D's turn synced the overlay \(inTurn) times, not once at the spring's start")
            // The turn ends (its scheduled sync, its commit) and the spring runs on the frozen clock.
            try? await Task.sleep(for: .milliseconds(100))
            try #require(try split.host("b").isOnRenderSpring, "the split landed on a frozen clock")
            let midFlight = split.root.overlaySyncs - before - inTurn
            #expect(midFlight == 0, "the overlay synced \(midFlight) times while the spring was mid-flight")
        }
    }

    /// The chrome lands on its host, and the landing syncs the overlay at most once more.
    @Test func theChromeLandsOnItsHost() async throws {
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let before = split.root.overlaySyncs
            split.split()
            #expect(await split.landed(), "the split did not land in 5 s")
            let syncs = split.root.overlaySyncs - before
            #expect(syncs >= 1 && syncs <= 2, "Cmd-D synced the overlay \(syncs) times")
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(Render.gap(host.chrome.frame, split.root.convert(host.bounds, from: host)) <= 0.001,
                        "\(pane)'s chrome did not land on its host")
            }
        }
    }

    /// The glow's outline at the chrome's rest size.
    static func restOutline(_ chrome: PaneOverlayView) -> CGPath? {
        let frames = chrome.chromeFrames(cellSize: chrome.bounds.size)
        return PaneOverlayView.ringOutline(size: frames.rounded.size, radius: frames.cornerRadius, width: chrome.attentionLayer.borderWidth)
    }

    /// `notifications.attention.terminals` glow: the ring never casts from its content. While it springs its
    /// model shadow path is the rest outline and keyframes give it the outline of its presented size; the
    /// follow ends with the ride (the landing, the take-back).
    @Test func aGlowingRingFollowsItsSpringWithAShadowPath() async throws {
        let design = DesignSettings.shared
        let saved = design.attention
        defer { design.attention = saved }
        var settings = AttentionSettings()
        settings.terminalRing = .glow
        design.attention = settings
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            split.model.attention["a"] = AttentionMark(generation: 1, quiet: true)
            split.root.syncWithModel()
            let a = try split.host("a")
            let ring = a.chrome.attentionLayer
            try #require(ring.opacity > 0 && ring.shadowOpacity > 0, "a's attention ring does not glow")
            #expect(ring.shadowPath == Self.restOutline(a.chrome), "the glowing ring has no outline at rest")

            split.split()
            try #require(a.isOnRenderSpring, "Cmd-D is not on the render server")
            #expect(ring.shadowPath == Self.restOutline(a.chrome), "the springing ring's model outline is not its rest one")
            let follow = try #require(ring.animation(forKey: CALayer.shadowPathFollowKey) as? CAKeyframeAnimation,
                                      "the springing ring's outline does not follow its size")
            #expect(follow.keyPath == "shadowPath" && (follow.values?.count ?? 0) > 2,
                    "the follow has \(follow.values?.count ?? 0) outlines, not one per frame of the spring")
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(ring.shadowPath == Self.restOutline(a.chrome), "the landing did not leave the rest outline")

            split.split(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                               b: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
            try #require(a.isOnRenderSpring, "the second split is not on the render server")
            #expect(ring.animation(forKey: CALayer.shadowPathFollowKey) != nil, "the second spring's outline does not follow")
            a.stopRenderMoves()
            #expect(ring.animation(forKey: CALayer.shadowPathFollowKey) == nil, "the take-back left the outline following")
            #expect(ring.shadowPath == Self.restOutline(a.chrome), "the take-back did not leave the rest outline")
        }
    }

    /// A strip of two columns beside a docked column, the second column split in two rows: a Cmd-Shift-D
    /// in the column the dock covers part of.
    static let dockedSplit = ScreenLayout.columns([
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
        LayoutColumn(id: "c2", width: 0.5, root: .split(SplitID("v"), axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
        LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
    ])

    /// A strip pane partly under a docked column shrinks (and the pane split from it grows in): the mask that
    /// cuts the dock out of its chrome keeps the cutout where the dock rests in the plane and covers all the
    /// chrome shows, so no ring or dim outside the rest rect is cut off; the take-back puts the rest mask back.
    @Test func theDockCutoutRidesWithTheChrome() async throws {
        try await Render.withMotion {
            let fixture = CloseRenderMotionTests.Screen(DockArrivalRenderMotionTests.docked, focused: "p1")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            try #require(fixture.stepToRest(), "the docked layout did not settle")
            try #require(try fixture.host("p2").chrome.layer?.mask != nil, "the dock does not cover p2: no cutout to ride")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.apply(Self.dockedSplit)
            let hosts = try [fixture.host("p2"), fixture.host("p3")]
            let spring = Motion.panes.spring(fixture.screen.motionState.frameSpring)
            for host in hosts {
                try #require(host.isOnRenderSpring, "\(host.pane) is not on the render server")
                let chrome = host.chrome
                let mask = try #require(chrome.layer?.mask, "\(host.pane)'s chrome has no dock cutout")
                let rest = chrome.frame.origin
                for progress in Self.progresses {
                    Render.seek(clock, to: Render.time(toProgress: progress, spring))
                    let shown = try Self.shown(chrome, root: fixture.root)
                    let size = try #require(chrome.layer?.presentation()).bounds.size
                    let presented = try #require(mask.presentation(), "the mask has no presentation")
                    let shift = CGPoint(x: presented.position.x - mask.position.x, y: presented.position.y - mask.position.y)
                    #expect(abs(shown.minX + shift.x - rest.x) <= 0.5 && abs(shown.minY + shift.y - rest.y) <= 0.5,
                            "\(host.pane) at \(progress): the cutout moved off the dock's rest with the chrome")
                    let covered = presented.bounds.offsetBy(dx: shift.x, dy: shift.y).insetBy(dx: -0.5, dy: -0.5)
                    #expect(covered.contains(CGRect(origin: .zero, size: size)),
                            "\(host.pane) at \(progress): the mask covers \(covered), the chrome shows \(size)")
                }
                host.stopRenderMoves()
                #expect(mask.animationKeys()?.isEmpty ?? true, "\(host.pane)'s mask still springs after the take-back")
                #expect(Render.gap(mask.frame, chrome.bounds) <= 0.001, "\(host.pane)'s mask does not cover its rest bounds")
            }
        }
    }

    /// A view whose y grows down, as the root, the plane and the screens.
    final class Flipped: NSView {
        nonisolated override var isFlipped: Bool { true }
    }

    /// A canvas camera zoomed out to 0.5 (`ScreenContentView.applyCamera` sets the screen's bounds size): the
    /// chrome's start and its velocity reach the plane through the zoom, as the host's frame does.
    @Test func theChromesStartConvertsThroughAZoomedCanvas() throws {
        let root = Flipped(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let canvas = Flipped(frame: CGRect(x: 100, y: 50, width: 400, height: 300))
        canvas.setBoundsSize(CGSize(width: 800, height: 600))
        root.addSubview(canvas)
        let start = try #require(PaneHostView.converted(CGRect(x: 200, y: 100, width: 400, height: 200),
                                                        velocity: RectComponents(x: 10, y: 20, width: 30, height: 40),
                                                        from: canvas) { rect, view in root.convert(rect, from: view) })
        #expect(Render.gap(start.rect, CGRect(x: 200, y: 100, width: 200, height: 100)) <= 0.001, "the start is at \(start.rect)")
        let velocity = start.velocity
        #expect(abs(velocity.x - 5) <= 0.001 && abs(velocity.y - 10) <= 0.001
                    && abs(velocity.width - 15) <= 0.001 && abs(velocity.height - 20) <= 0.001,
                "the velocity is \(velocity), not the canvas's at half its size")
    }
}
