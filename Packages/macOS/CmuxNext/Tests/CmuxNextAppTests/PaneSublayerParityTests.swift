import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Pane chrome on the render server (chrome-parity p03-rendering-029, `motion.renderServer` on): the ring,
/// glow, attention ring, border, dim and focus flash ride their pane's spring. The overlay's frame follows
/// the host's presented frame, and each sublayer that keeps its thickness sits where the overlay's layout
/// puts it for the size the pane shows, within 0.5 pt at 25, 50 and 75 % of Cmd-D, of a Cmd-D that
/// retargets half way, and of Cmd-W. Without its own springs a sublayer shows its rest frame from the
/// first frame (Core Animation lays sublayers out for the model bounds only), and the overlay, placed once
/// at rest, shows the pane's rest frame while the pane still moves.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct PaneSublayerParityTests {
    typealias Render = SplitRenderMotionTests

    /// Where the parity is sampled along a spring.
    static let progresses: [Double] = [0.25, 0.5, 0.75]

    /// `rect`, a frame in the backing layer space of `view`'s superview, in `root`'s coordinates.
    static func inRoot(_ rect: CGRect, of view: NSView, root: LayoutRootView) throws -> CGRect {
        let superview = try #require(view.superview, "\(view) is in no view")
        return root.convert(superview.convertFromLayer(rect), from: superview)
    }

    /// The frame `view` presents now, in `root`'s coordinates.
    static func shown(_ view: NSView, root: LayoutRootView) throws -> CGRect {
        let layer = try #require(view.layer?.presentation(), "no presentation layer after a commit")
        return try inRoot(layer.frame, of: view, root: root)
    }

    /// At each of ``progresses`` of a spring that began at `start` on the frozen `clock`: every host's chrome
    /// shows on its host's presented frame, and every chrome sublayer where the chrome's layout puts it for
    /// the size it shows.
    static func expectParity(_ hosts: [PaneHostView], root: LayoutRootView, spring: SpringParameters, clock: CALayer,
                             start: CFTimeInterval = 0) throws {
        for progress in progresses {
            Render.seek(clock, to: start + Render.time(toProgress: progress, spring))
            for host in hosts {
                let chrome = host.chrome
                let hostShown = try shown(host, root: root), chromeShown = try shown(chrome, root: root)
                #expect(Render.gap(hostShown, chromeShown) <= 0.5,
                        "\(host.pane) at \(progress): the chrome shows \(chromeShown), its host \(hostShown)")
                let size = try #require(chrome.layer?.presentation()).bounds.size
                for (sublayer, expected) in chrome.sublayerFrames(chrome.chromeFrames(cellSize: size)) {
                    let presented = try #require(sublayer.presentation(), "a chrome sublayer has no presentation").frame
                    #expect(Render.gap(presented, expected) <= 0.5,
                            "\(host.pane) at \(progress): a chrome sublayer shows \(presented), not \(expected) for \(size)")
                }
            }
        }
    }

    @Test func theChromeRidesCmdD() async throws {
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            Render.freeze(clock)
            split.split()
            let hosts = try [split.host("a"), split.host("b")]
            for host in hosts {
                #expect(host.chrome.superview === split.root.overlayPlane, "\(host.pane)'s chrome is not in the plane")
            }
            // The chrome moves: at the spring's start a still shows its whole-window frame.
            Render.seek(clock, to: 0)
            let a = hosts[0]
            let start = try Self.shown(a.chrome, root: split.root), rest = split.root.convert(a.bounds, from: a)
            #expect(Render.gap(start, rest) > 100, "a's chrome starts at its rest \(rest)")
            try Self.expectParity(hosts, root: split.root, spring: Motion.panes.spring(split.screen.motionState.frameSpring),
                                  clock: clock)
        }
    }

    /// Cmd-D on the pane still growing in, half way: the springs come back to the CPU frames, and the chrome
    /// springs again from where it shows with its hosts.
    @Test func theChromeRidesACmdDThatRetargets() async throws {
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            Render.freeze(clock)
            split.split()
            let spring = Motion.panes.spring(split.screen.motionState.frameSpring)
            let half = Render.time(toProgress: 0.5, spring)
            Render.seek(clock, to: half)
            split.split(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                               b: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
            try #require(try split.host("c").isOnRenderSpring, "the second split is not on the render server")
            try Self.expectParity([split.host("a"), split.host("b"), split.host("c")], root: split.root, spring: spring,
                                  clock: clock, start: half)
        }
    }

    @Test(arguments: [SplitAxis.horizontal, .vertical])
    func theChromeRidesCmdW(_ axis: SplitAxis) async throws {
        try await Render.withMotion {
            let fixture = CloseRenderMotionTests.Screen(CloseRenderMotionTests.pair(axis), focused: "b")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.close(to: .splits(.leaf("a")), focus: "a")
            let host = try fixture.host("a")
            try #require(host.isOnRenderSpring, "the close is not on the render server")
            try Self.expectParity([host], root: fixture.root, spring: Motion.panes.spring(fixture.screen.motionState.frameSpring),
                                  clock: clock)
        }
    }

    /// The overlay syncs when the spring starts and, at most, when it lands: never on its frames.
    @Test func cmdDSyncsTheOverlayAtMostTwice() async throws {
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
}
