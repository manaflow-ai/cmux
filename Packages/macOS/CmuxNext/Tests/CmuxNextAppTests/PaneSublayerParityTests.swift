import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import CmuxNextWakeups
import Testing

/// Pane chrome on the render server (`motion.renderServer` on): the ring,
/// glow, attention ring, border, dim and focus flash ride their pane's spring. The overlay's frame follows
/// the host's presented frame, and each sublayer that keeps its thickness sits where the overlay's layout
/// puts it for the size the pane shows, within 0.5 pt at the start and at 25, 50 and 75 % of Cmd-D, of
/// Cmd-Shift-D under a tab strip, of a Cmd-D that retargets half way, and of Cmd-W. Without its own springs
/// a sublayer shows its rest frame from the first frame (Core Animation lays sublayers out for the model
/// bounds only), and the overlay, placed once at rest, shows the pane's rest frame while the pane still moves.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct PaneSublayerParityTests {
    typealias Render = SplitRenderMotionTests

    /// Where the parity is sampled along a spring: its start, where a pane growing in from a zero seed is
    /// below the chrome's clamps, and three points past them.
    static let progresses: [Double] = [0, 0.25, 0.5, 0.75]

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

    /// At each of ``progresses`` of a spring with `spring`'s tuning that began at `start` on the frozen `clock`:
    /// every host's chrome shows on its host's presented frame, and every chrome sublayer where the chrome's
    /// layout puts it for the size it shows. Where that layout is an empty rect (a cell below its clamps), the
    /// sublayer draws nothing either.
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
                    let presented = try #require(sublayer.presentation(), "a chrome sublayer has no presentation")
                    if expected.width < 0.5 || expected.height < 0.5 {
                        let drawn = presented.bounds.size
                        #expect(drawn.width < 0.5 || drawn.height < 0.5,
                                "\(host.pane) at \(progress): a chrome sublayer draws \(drawn) where the layout for \(size) is empty")
                    } else {
                        #expect(Render.gap(presented.frame, expected) <= 0.5,
                                "\(host.pane) at \(progress): a chrome sublayer shows \(presented.frame), not \(expected) for \(size)")
                    }
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

    /// Cmd-Shift-D on a padded pane under a tab strip: the new pane grows in from a zero-height seed, and its
    /// ring, border and dim keep the padding and the strip's band above them from the first frame on, so no
    /// ring or dim draws across the new pane's tab strip while it grows.
    @Test func theChromeRidesCmdShiftDUnderATabStrip() async throws {
        try await Render.withMotion {
            let split = HeadedSplit()
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let a = try split.host("a")
            try #require(a.headerHeight == Self.header, "the pane content reports no tab strip")
            let clock = try #require(split.root.layer)
            Render.freeze(clock)
            split.split(.split(SplitID("d"), axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            let b = try split.host("b")
            try #require(b.isOnRenderSpring, "Cmd-Shift-D is not on the render server")
            try Self.expectParity([a, b], root: split.root, spring: Motion.panes.spring(split.screen.motionState.frameSpring),
                                  clock: clock)
        }
    }

    /// Cmd-D on the pane still growing in, half way: the springs come back to the CPU frames, and the chrome
    /// springs again from where it shows with its hosts, on the second spring.
    @Test func theChromeRidesACmdDThatRetargets() async throws {
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            Render.freeze(clock)
            split.split()
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(split.screen.motionState.frameSpring))
            Render.seek(clock, to: half)
            split.split(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                               b: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
            try #require(try split.host("c").isOnRenderSpring, "the second split is not on the render server")
            let second = Motion.panes.spring(split.screen.motionState.frameSpring)
            try Self.expectParity([split.host("a"), split.host("b"), split.host("c")], root: split.root, spring: second,
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

    // MARK: A padded pane under a tab strip

    /// The tab strip's height in ``HeadedSplit``.
    static let header: CGFloat = 30

    /// Pane content with a tab strip on top (`PaneContentChrome`): the ring and border leave its band out.
    final class Headed: NSView, PaneContentChrome {
        var paneHeaderHeight: CGFloat { PaneSublayerParityTests.header }
        var onPaneHeaderHeightChange: (() -> Void)?
        func setPaneContentCornerRadius(_ radius: CGFloat) {}
    }

    final class HeadedPanes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView {
            let content = Headed()
            content.wantsLayer = true
            return content
        }
    }

    /// One pane `a` in a 1200 x 800 window, padded 4 pt with 8 pt corners, under a tab strip.
    final class HeadedSplit {
        let panes = HeadedPanes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("a")))], activeScreenID: "s",
                                focusedPane: "a")
            model.followsDesignMetrics = false
            model.baseStyle.panePadding = 4
            model.baseStyle.paneCornerRadius = 8
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { true }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func host(_ pane: PaneID) throws -> PaneHostView { try #require(root.context.hosts[pane]) }

        /// The daemon's tree after a split, in the key's turn.
        func split(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        func close() {
            window.orderOut(nil)
            window.close()
        }
    }
}
