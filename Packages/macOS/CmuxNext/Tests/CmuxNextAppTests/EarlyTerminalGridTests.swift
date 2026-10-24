import AppKit
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Testing

/// Lawrence 2026-10-23: "for cmd d and then cmd w, we need to trigger TUI resize much faster, even
/// before animation starts or finishes playing". A split or a close tells every pane's content the
/// size it will rest at in the key's turn, before the first moving frame, so a terminal sends its
/// final PTY grid at once (the TUI redraws at its new size while the pane moves) and sends nothing
/// more when the spring lands. This suite pins the announcement only: the layout's grid hold stays
/// until an app terminal answers it (TerminalSurfaceView conforms to `PaneMotionTargeting`) and a
/// terminal that attaches mid-spring reports its rest grid (SplitTerminalResizeCountTests).
///
/// Contract this suite pins (PL-motion-core, PL-ghostty, written by PL-burst): `PaneMotionTargeting
/// .paneMotionWillRest(sizeChange:)` (CmuxNextDesign), called once per motion with the change from the content
/// view's size now to the size it rests at (`bounds.size + sizeChange`), in the turn that starts the motion.
/// Frames step at a fixed 120 Hz dt; the display link never ticks.
@MainActor
struct EarlyTerminalGridTests {
    /// A pane's content that records what the layout tells it.
    final class Content: NSView, PaneMotionSettling, PaneMotionTargeting {
        var restingSizes: [CGSize] = []
        var settled = 0
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
            restingSizes.append(CGSize(width: bounds.width + sizeChange.width, height: bounds.height + sizeChange.height))
            return .top
        }
        func paneMotionDidSettle() { settled += 1 }
    }

    final class Panes: LayoutPaneContentProvider {
        var contents: [PaneID: Content] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let content = Content()
            contents[pane] = content
            return content
        }
    }

    static let dt = 1.0 / 120

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ tree: SplitNode) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        /// Steps until nothing moves (at most 2 s).
        func settle() {
            for _ in 1...240 {
                if !root.advanceFrame(EarlyTerminalGridTests.dt) { return }
            }
        }
    }

    static let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    static let pairSplit: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                             b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
    static let row: SplitNode = .split("r1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                       b: .split("r2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    /// Cmd-D: every pane of the chain knows its resting size in the key's turn, it is the size it
    /// rests at, and it is told once (nothing again at landing).
    @Test func aSplitGivesEveryPaneItsRestingSizeInTheKeysTurn() throws {
        let screen = Screen(Self.pair)
        let changes = screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal)
        _ = screen.model.showSplitSizing(changes)
        screen.show(Self.pairSplit)
        for pane: PaneID in ["p1", "p2", "p3"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes.count == 1, "\(pane) was told \(content.restingSizes.count) resting sizes in the key's turn")
        }
        screen.settle()
        for pane: PaneID in ["p1", "p2", "p3"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes == [content.frame.size], "\(pane): told \(content.restingSizes), rests at \(content.frame.size)")
        }
    }

    /// Cmd-W on p2's last tab: the panes that grow know their resting size in the key's turn, once.
    @Test func aCloseGivesTheGrowingPanesTheirRestingSizeInTheKeysTurn() throws {
        let screen = Screen(Self.row)
        screen.settle()
        for content in screen.provider.contents.values { content.restingSizes.removeAll() }
        _ = try #require(screen.model.showPaneClose("p2"))
        screen.root.syncWithModel()
        for pane: PaneID in ["p1", "p3"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes.count == 1, "\(pane) was told \(content.restingSizes.count) resting sizes in the key's turn")
        }
        screen.settle()
        for pane: PaneID in ["p1", "p3"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes == [content.frame.size], "\(pane): told \(content.restingSizes), rests at \(content.frame.size)")
        }
    }

    /// A second Cmd-D while the first springs: each pane is told its new resting size in that
    /// press's turn (one more), never a size it will not rest at.
    @Test func aSplitDuringASplitRetellsOnlyTheNewRestingSize() throws {
        let screen = Screen(Self.pair)
        _ = screen.model.showSplitSizing(screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal))
        screen.show(Self.pairSplit)
        for _ in 1...6 { screen.root.advanceFrame(Self.dt) }
        let triple: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                       b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"),
                                                 b: .split("m", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))))
        _ = screen.model.showSplitSizing(screen.model.splitSizingChanges(splitting: "p3", axis: .horizontal))
        screen.show(triple)
        screen.settle()
        for pane: PaneID in ["p1", "p2", "p3", "p4"] {
            let content = try #require(screen.provider.contents[pane])
            #expect(content.restingSizes.last == content.frame.size, "\(pane): last told \(String(describing: content.restingSizes.last)), rests at \(content.frame.size)")
            #expect(content.restingSizes.count <= 2, "\(pane) was told \(content.restingSizes.count) sizes for two presses")
        }
    }
}
