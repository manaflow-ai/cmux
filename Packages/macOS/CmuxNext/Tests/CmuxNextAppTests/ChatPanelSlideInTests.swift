import AppKit
import CmuxNextTestSupport
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// A panel opening on a chat's right is one motion that never resizes the panel (Leo 2026-11-06: "we need to have our
/// animations be more one-step like codex their agent pane flows smoothly when a thing opens up on the right evne when
/// there's big lag on the computer"). The chat holds its layout while it moves (the provider's `holdsContentInMotion`), and
/// the panel enters at its final width from the chat's edge and slides in on the split spring (`PaneArrival.slidingIn`),
/// so its page lays out once and every frame after only moves it. A split of a pane that does not hold its content
/// (Cmd-D in a terminal) still grows from a sliver. Frames step at a fixed 120 Hz dt.
@MainActor
@Suite(.closesItsWindows)
struct ChatPanelSlideInTests {
    final class Panes: LayoutPaneContentProvider {
        let holding: Set<PaneID>
        init(holding: Set<PaneID>) { self.holding = holding }
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
        func holdsContentInMotion(for pane: PaneID) -> Bool { holding.contains(pane) }
    }

    static let dt = 1.0 / 120

    final class Screen {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ tree: SplitNode, holding: Set<PaneID>) {
            provider = Panes(holding: holding)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        var screen: ScreenContentView? { root.screenViews["s"] }

        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        func rect(_ pane: PaneID) -> CGRect? { screen?.paneFrames[pane]?.rect }
        func target(_ pane: PaneID) -> CGRect? { screen?.paneFrames[pane]?.targetRect }

        @discardableResult
        func step() -> Bool { root.advanceFrame(ChatPanelSlideInTests.dt) }
    }

    static let opened: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("chat"), b: .leaf("panel"))

    @Test func aPanelOpeningBesideAChatSlidesInAtItsFinalWidth() throws {
        let screen = Screen(.leaf("chat"), holding: ["chat"])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let panel = try #require(screen.target("panel")), chat = try #require(screen.target("chat"))
        let gap = panel.minX - chat.maxX
        let first = try #require(screen.rect("panel"))
        #expect(first.width == panel.width, "the panel starts at its final width, not as a sliver: \(first)")
        #expect(first.minX > panel.minX + 1, "the panel starts right of where it rests: \(first) vs \(panel)")
        var landed: Int?, xs: [CGFloat] = []
        for frame in 1...120 {
            let moving = screen.step()
            let shown = try #require(screen.rect("panel")), left = try #require(screen.rect("chat"))
            // Its size never changes: the page is never laid out at a size no frame rests at.
            #expect(abs(shown.width - panel.width) < 0.01 && abs(shown.height - panel.height) < 0.01,
                    "frame \(frame): the panel resized to \(shown.size)")
            // It rides the chat's edge: one gap between them in every frame, nothing shows between.
            #expect(abs(shown.minX - left.maxX - gap) < 0.01, "frame \(frame): the gap is \(shown.minX - left.maxX), not \(gap)")
            xs.append(shown.minX)
            if !moving { landed = frame; break }
        }
        #expect(landed != nil, "the slide never landed")
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 <= $0 + 0.25 }, "the panel moved back: \(xs)")
        #expect(screen.rect("panel") == panel)
    }

    /// Cmd-D in a pane that lays out live (a terminal) keeps its sliver: split-spring-animation/DESIGN.md.
    @Test func aSplitOfAPaneThatDoesNotHoldItsContentStillGrowsFromASliver() throws {
        let screen = Screen(.leaf("chat"), holding: [])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let panel = try #require(screen.target("panel"))
        screen.step()
        let first = try #require(screen.rect("panel"))
        #expect(first.width < panel.width - 1, "a terminal's split grows in: \(first)")
    }

    /// A pane opening between the chat and another pane would cover that pane if it came in at its full width: it grows.
    @Test func aPaneOpeningBetweenTwoPanesGrowsFromASliver() throws {
        let start: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("chat"), b: .leaf("right"))
        let screen = Screen(start, holding: ["chat"])
        defer { screen.window.closeAfterTest() }
        screen.show(.split("r", axis: .horizontal, ratio: 0.5,
                           a: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("chat"), b: .leaf("panel")), b: .leaf("right")))
        let panel = try #require(screen.target("panel"))
        screen.step()
        let first = try #require(screen.rect("panel"))
        #expect(first.width < panel.width - 1, "a pane between two panes grows in: \(first)")
    }

    @Test func onlyARightwardArrivalAtTheTrailingEdgeSlides() {
        let target = CGRect(x: 600, y: 0, width: 600, height: 800)
        let sideways = PaneArrival(seed: CGRect(x: 1200, y: 0, width: 0, height: 800), edgeOffset: CGVector(dx: 600, dy: 0), giver: "chat")
        let slid = sideways.slidingIn(target: target, clipMaxX: 1200)
        #expect(slid.slides && slid.seed == CGRect(x: 1200, y: 0, width: 600, height: 800))
        let down = PaneArrival(seed: CGRect(x: 600, y: 800, width: 600, height: 0), edgeOffset: CGVector(dx: 0, dy: 400), giver: "chat")
        #expect(!down.slidingIn(target: target, clipMaxX: 1200).slides, "a split down grows")
        let left = PaneArrival(seed: CGRect(x: 0, y: 0, width: 0, height: 800), edgeOffset: CGVector(dx: -600, dy: 0), giver: "chat")
        #expect(!left.slidingIn(target: CGRect(x: 0, y: 0, width: 600, height: 800), clipMaxX: 1200).slides, "a split left grows")
        #expect(!sideways.slidingIn(target: target, clipMaxX: 1400).slides, "short of the trailing edge it grows")
    }
}
