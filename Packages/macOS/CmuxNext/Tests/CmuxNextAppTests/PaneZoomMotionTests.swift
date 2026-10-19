import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import Testing

/// Zoom and unzoom (Leo 2026-10-13, Lawrence 2026-10-18): the expanding pane owns the motion and
/// its terminal draws once at its final size; it covers the other panes, which never fade and
/// are let go once it lands. Frames step at a fixed 120 Hz dt, so every
/// assertion is about frame N, not wall time.
@MainActor
struct PaneZoomMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let tree: SplitNode

        init(_ tree: SplitNode, reduceMotion: Bool = false) {
            self.tree = tree
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
        }

        var screen: ScreenContentView? { root.screenViews["s"] }

        func zoom(_ pane: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(pane)), zoomed: true)])
            root.syncWithModel()
        }

        func unzoom() {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        /// How much of `pane` shows: 0 once its host is hidden, gone, transparent or clipped away.
        func opacity(_ pane: PaneID) -> CGFloat {
            guard let host = root.context.hosts[pane], host.superview != nil, !host.isHidden else { return 0 }
            if let clip = host.layer?.mask?.frame, clip.width < 0.5 || clip.height < 0.5 { return 0 }
            return host.alphaValue
        }

        func hostSize(_ pane: PaneID) -> CGSize? { root.context.hosts[pane]?.frame.size }

        func shown(_ pane: PaneID) -> CGRect? { screen?.displayedFrame(of: pane) }

        @discardableResult
        func step() -> Bool { root.advanceFrame(PaneZoomMotionTests.dt) }
    }

    /// p1 p2 / p3 p4.
    static let grid2: SplitNode = .split("v", axis: .vertical, ratio: 0.5,
                                         a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                         b: .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))

    static func row(_ id: String, _ panes: [PaneID]) -> SplitNode {
        .split(SplitID("\(id)1"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf(panes[0]),
               b: .split(SplitID("\(id)2"), axis: .horizontal, ratio: 0.5, a: .leaf(panes[1]), b: .leaf(panes[2])))
    }

    /// p1 p2 p3 / p4 p5 p6 / p7 p8 p9.
    static let grid3: SplitNode = .split("r1", axis: .vertical, ratio: 1.0 / 3, a: row("a", ["p1", "p2", "p3"]),
                                         b: .split("r2", axis: .vertical, ratio: 0.5, a: row("b", ["p4", "p5", "p6"]),
                                                   b: row("c", ["p7", "p8", "p9"])))

    /// The token's time scale (`ui.animationSpeed`), so budgets hold at any speed.
    static var scale: Double { Motion.spring(.move).response / MotionSpring.move.base.response }

    @Test(arguments: [("p1", "p4"), ("p4", "p1"), ("p2", "p3")])
    func inA2x2ZoomTheZoomedPaneCoversTheOthersWhichNeverFade(zoomed: String, opposite: String) throws {
        let screen = Screen(Self.grid2)
        let pane = PaneID(zoomed), corner = PaneID(opposite)
        let others = (Set(Self.grid2.panes) as Set<PaneID>).subtracting([pane])
        screen.zoom(pane)
        let target = try #require(screen.screen?.geometry.panes[pane])
        let final = try #require(screen.hostSize(pane))
        var reached: Int?, released: Int?
        for frame in 1...120 {
            screen.step()
            // Lawrence 2026-10-18: cover, never fade. A covered pane is opaque until it is let go.
            for other in others { if let host = screen.root.context.hosts[other], host.superview != nil { #expect(host.alphaValue == 1, "frame \(frame): \(other) faded") } }
            if frame == 1 { #expect(screen.opacity(corner) == 1, "the opposite corner vanished at once") }
            #expect(screen.hostSize(pane) == final, "frame \(frame): the zoomed terminal resized mid-move")
            if reached == nil, let shown = screen.shown(pane), shown.width >= target.width * 0.95, shown.height >= target.height * 0.95 {
                reached = frame
            }
            if released == nil, others.allSatisfy({ screen.root.context.hosts[$0]?.superview == nil }) { released = frame }
        }
        #expect(abs(final.width - target.width) < 1 && abs(final.height - target.height) < 1)
        // The zoomed pane reaches 95% within 0.35 s; the covered panes are let go once it lands.
        #expect((reached ?? .max) <= Int((0.35 * Self.scale / Self.dt).rounded(.up)), "95% at frame \(reached.map(String.init) ?? "never")")
        #expect((released ?? .max) >= (reached ?? 0), "a covered pane was let go before the zoom reached its rect")
        #expect(released != nil, "the covered panes were never let go")
    }

    @Test func aCenterZoomIn3x3ResizesItsTerminalOnceAndLetsGoOfTheCoveredPanesWhenItLands() throws {
        let screen = Screen(Self.grid3)
        screen.zoom("p5")
        let final = try #require(screen.hostSize("p5"))
        for frame in 1...120 {
            screen.step()
            #expect(screen.hostSize("p5") == final, "frame \(frame): the zoomed terminal resized mid-move")
        }
        #expect(Self.grid3.panes.filter({ $0 != "p5" }).allSatisfy({ screen.opacity($0) == 0 }))
    }

    @Test func anUnzoomMidZoomKeepsTheMotionsVelocityAndTheLeavingPanesComeBackFromWhereTheyAre() throws {
        let screen = Screen(Self.grid2)
        screen.zoom("p1")
        var widths: [CGFloat] = []
        for _ in 1...6 {
            screen.step()
            widths.append(try #require(screen.shown("p1")).width)
        }
        let corner = screen.opacity("p4")
        #expect(widths[5] > widths[4])
        screen.unzoom()
        // Nothing jumps at the interrupt, and the spring keeps its velocity: from rest it would
        // start shrinking at once, carried it still grows for a frame.
        #expect(screen.shown("p1")?.width == widths[5], "the zoomed pane jumped on the interrupt")
        #expect(abs(screen.opacity("p4") - corner) < 0.02, "the opposite corner jumped on the interrupt")
        screen.step()
        let after = try #require(screen.shown("p1")).width - widths[5]
        #expect(after > 0, "velocity lost: the unzoom started from rest")
        let returning = try #require(screen.hostSize("p2"))
        for frame in 1...120 {
            screen.step()
            #expect(screen.hostSize("p2") == returning, "frame \(frame): a returning terminal resized mid-move")
        }
        #expect(screen.opacity("p4") == 1)
        #expect(screen.shown("p1") == screen.screen?.geometry.panes["p1"])
    }

    @Test func anUnzoomResizesTheTerminalOnceAsItLandsAndUncoversTheOthers() throws {
        let screen = Screen(Self.grid2)
        screen.zoom("p4")
        for _ in 1...120 { screen.step() }
        screen.unzoom()
        // It keeps its zoomed size while the shrinking rect clips it, and takes its slot's once, as it lands.
        var sizes = [try #require(screen.hostSize("p4"))]
        let slot = try #require(screen.screen?.geometry.panes["p4"])
        #expect(screen.opacity("p1") < 0.05, "a returning pane shows over the zoomed one before it shrinks")
        var shown: Int?
        for frame in 1...120 {
            screen.step()
            if let size = screen.hostSize("p4"), size != sizes.last { sizes.append(size) }
            // Uncovered as the zoomed pane shrinks, not popping in as it lands.
            if frame == 12 { #expect(["p1", "p2", "p3"].allSatisfy { screen.opacity($0) > 0.3 }, "a returning pane is still cut away") }
            if shown == nil, ["p1", "p2", "p3"].allSatisfy({ screen.opacity($0) > 0.95 }) { shown = frame }
        }
        #expect(sizes.count <= 2, "the unzooming terminal resized \(sizes.count - 1) times: \(sizes)")
        #expect(sizes.last.map { abs($0.width - slot.width) < 1 && abs($0.height - slot.height) < 1 } == true)
        #expect((shown ?? .max) <= Int((0.35 * Self.scale / Self.dt).rounded(.up)))
    }

    @Test func reduceMotionZoomsAndUnzoomsInOneFrame() throws {
        let screen = Screen(Self.grid2, reduceMotion: true)
        screen.zoom("p1")
        #expect(screen.shown("p1") == screen.screen?.geometry.panes["p1"])
        #expect(["p2", "p3", "p4"].allSatisfy { screen.opacity($0) == 0 })
        screen.unzoom()
        #expect(["p1", "p2", "p3", "p4"].allSatisfy { screen.opacity($0) == 1 })
        #expect(screen.shown("p1") == screen.screen?.geometry.panes["p1"])
    }

    @Test func anArrivingSplitPaneFadesItsContentWhileItsHostKeepsTheFinalSize() throws {
        let paneAnimations = DesignSettings.shared.paneAnimations
        DesignSettings.shared.paneAnimations = true
        defer { DesignSettings.shared.paneAnimations = paneAnimations }
        let screen = Screen(.leaf("p1"))
        let split = SplitNode.split("v", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))])
        screen.root.syncWithModel()

        let pane = try #require(screen.screen?.paneFrames["p2"])
        #expect(pane.alpha.value == 0, "the arriving pane content popped in before its fade")
        let final = try #require(screen.hostSize("p2"))
        #expect(final.width > 0 && final.height > 0, "the arriving content did not get its final host size")

        screen.step()
        let first = try #require(screen.screen?.paneFrames["p2"]?.alpha.value)
        #expect(first > 0 && first < 1, "the arriving pane fade did not advance independently")
        #expect(screen.hostSize("p2") == final, "the arriving pane resized while its content faded")

        for _ in 0..<120 { screen.step() }
        #expect(screen.opacity("p2") == 1, "the arriving pane fade did not settle")
    }
}
