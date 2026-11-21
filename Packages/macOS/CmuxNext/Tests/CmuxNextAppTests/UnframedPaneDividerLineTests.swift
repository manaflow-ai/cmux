import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/37425: under `appearance.chromeStyle` panes (each pane
/// outlined, `borders`), an agent chat beside a New Tab page had nothing between them. Neither draws
/// a pane outline (`PaneContentChrome.paneFramesContent` is false: they share the window's glass), and
/// a split's line rests hidden while panes have borders. A split now draws its resting line beside a
/// pane that draws no outline, and takes it back when that pane's content frames itself again.
@MainActor
@Suite(.closesItsWindows)
struct UnframedPaneDividerLineTests {
    /// Content that reports whether it draws its pane's outline, as `PaneContentView` does for an agent chat.
    final class Content: NSView, PaneContentChrome {
        var framed: Bool
        init(framed: Bool) {
            self.framed = framed
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        var paneFramesContent: Bool { framed }
        var paneHeaderHeight: CGFloat { 28 }
        var onPaneHeaderHeightChange: (() -> Void)?
        func setPaneContentCornerRadius(_ radius: CGFloat) {}

        /// Another tab's content shows: the pane re-reads its chrome.
        func show(framed: Bool) {
            self.framed = framed
            onPaneHeaderHeightChange?()
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var framed: [PaneID: Bool]
        var made: [PaneID: Content] = [:]
        init(framed: [PaneID: Bool]) { self.framed = framed }
        func makeContentView(for pane: PaneID) -> NSView {
            let view = Content(framed: framed[pane] ?? true)
            made[pane] = view
            return view
        }
    }

    final class Harness {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        static let oneSplit = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]

        init(framed: [PaneID: Bool], separation: PaneSeparation = .borders, hitWidth: CGFloat? = nil,
             columns: [LayoutColumn] = Harness.oneSplit) {
            _ = NSApplication.shared
            provider = Panes(framed: framed)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "p1")
            var style = LayoutStyle()
            style.paneSeparation = separation
            style.showsPaneBorder = separation == .borders
            style.drawsLines = true
            style.panePadding = 0
            style.columnGap = 0
            if let hitWidth { style.dividerHitThickness = hitWidth }
            model.followsDesignMetrics = false
            model.baseStyle = style
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        var handle: DividerHandleView {
            get throws { try #require(root.screenViews["s"]?.dividerViews[.split("x")]) }
        }
    }

    @Test func twoChatsSideBySideUnderOutlinedPanesHaveALineBetweenThem() throws {
        let harness = Harness(framed: ["p1": false, "p2": false])
        defer { harness.window.closeAfterTest() }
        #expect(try harness.handle.isLineVisible, "a chat beside a New Tab page: nothing drew between them")
        #expect(!harness.root.interactiveOverlayRects.isEmpty, "the line is reported, so a page leaves it uncovered")
    }

    @Test func oneUnframedNeighbourIsEnough() throws {
        let harness = Harness(framed: ["p1": true, "p2": false])
        defer { harness.window.closeAfterTest() }
        #expect(try harness.handle.isLineVisible)
    }

    @Test func outlinedPanesKeepTheirOutlinesAndNoLine() throws {
        let harness = Harness(framed: ["p1": true, "p2": true])
        defer { harness.window.closeAfterTest() }
        #expect(try !harness.handle.isLineVisible, "the panes' own outlines separate them")
    }

    @Test func theLineFollowsWhatThePaneShows() throws {
        let harness = Harness(framed: ["p1": true, "p2": true])
        defer { harness.window.closeAfterTest() }
        let content = try #require(harness.provider.made["p2"])
        content.show(framed: false)
        #expect(try harness.handle.isLineVisible, "a chat tab took the pane: the line shows")
        content.show(framed: true)
        #expect(try !harness.handle.isLineVisible, "a terminal tab is back: its outline separates it again")
    }

    /// A drag width as thin as the line (`dividerHitWidth` 1): the panes only touch the hit area, and still count.
    @Test func aThinDragWidthStillFindsTheChatBesideIt() throws {
        let harness = Harness(framed: ["p1": true, "p2": false], hitWidth: 1)
        defer { harness.window.closeAfterTest() }
        #expect(try harness.handle.isLineVisible)
    }

    /// Flush columns (no strip gap, as borders at comfortable density): a chat in the next column
    /// does not light a split between two outlined terminals in this one. Only the split's own
    /// panes count (review of https://github.com/manaflow-ai/cmux/pull/37451 at b5faf89fe4).
    @Test func aChatInTheNextColumnDoesNotLightThisColumnsSplit() throws {
        let columns = [
            LayoutColumn(id: "c0", width: 0.5, root: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("p3")),
        ]
        let harness = Harness(framed: ["p1": true, "p2": true, "p3": false], columns: columns)
        defer { harness.window.closeAfterTest() }
        let handle = try #require(harness.root.screenViews["s"]?.dividerViews[.split("y")])
        #expect(!handle.isLineVisible, "the outlined terminals' own split drew a line for the chat beside the column")
    }

    /// `none` and `cards` keep their own look: no line at rest beside a chat either.
    @Test func separationsWithoutLinesStayWithoutLines() throws {
        for separation in [PaneSeparation.none, .cards] {
            let harness = Harness(framed: ["p1": false, "p2": false], separation: separation)
            defer { harness.window.closeAfterTest() }
            #expect(try !harness.handle.isLineVisible, "\(separation)")
        }
    }
}
