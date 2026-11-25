import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// Equalize Splits on columns (Lawrence 2026-11-05: "cmd ctrl = fails to equalize home imessage/chief and the stuff on
/// the right… is it because they're columns?"). Ctrl-Cmd-= set only split ratios: column widths, and Home's Chief dock,
/// kept whatever width they had. Now every column a person sees side by side ends the same width on screen, Home's
/// docked chat included (clamped to its minimum), and the splits inside each column are even.
@MainActor
struct EqualizeColumnsTests {
    static let homeDock = DockColumn(edge: .left, role: .agentChat, isPinned: true)

    static var style: LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        return style
    }

    static func model(_ columns: [LayoutColumn], visible: [PaneID]? = nil) -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))])
        model.followsDesignMetrics = false
        model.baseStyle = style
        model.reportVisiblePanes(Set(visible ?? columns.flatMap(\.root.panes)), keepAlive: [])
        return model
    }

    /// The on-screen widths, in visual order (left dock first), of `ids` after the model's change.
    static func widths(_ model: LayoutModel, _ ids: [ColumnID], viewport: CGSize) -> [CGFloat] {
        let geometry = ScreenGeometry.compute(model.screens[0].layout, viewport: viewport, style: model.style)
        return ids.map { geometry.columns[$0]?.width ?? -1 }
    }

    static func expectEqual(_ widths: [CGFloat], _ note: Comment) {
        guard let first = widths.first else { return }
        #expect(widths.allSatisfy { abs($0 - first) <= 1 }, "\(note): \(widths)")
    }

    @Test(arguments: [CGFloat(1440), 1920, 2560])
    func homeChatAndOneColumnGetTheSameWidth(viewportWidth: CGFloat) {
        let viewport = CGSize(width: viewportWidth, height: 900)
        let model = Self.model([
            LayoutColumn(id: "home", width: 0.3, root: .leaf("chat"), dock: Self.homeDock),
            LayoutColumn(id: "c1", width: 1, root: .leaf("p1")),
        ])
        #expect(model.equalize(screen: "s", viewportWidth: viewport.width) == .equalized)
        Self.expectEqual(Self.widths(model, ["home", "c1"], viewport: viewport), "chat + 1 column at \(viewportWidth)")
    }

    @Test func homeChatAndTwoColumnsGetTheSameWidth() {
        let viewport = CGSize(width: 1920, height: 1080)
        let model = Self.model([
            LayoutColumn(id: "home", width: 0.5, root: .leaf("chat"), dock: Self.homeDock),
            LayoutColumn(id: "c1", width: 0.7, root: .split("v", axis: .vertical, ratio: 0.8, a: .leaf("p1"), b: .leaf("p2"))),
            LayoutColumn(id: "c2", width: 0.3, root: .leaf("p3")),
        ])
        #expect(model.equalize(screen: "s", viewportWidth: viewport.width) == .equalized)
        Self.expectEqual(Self.widths(model, ["home", "c1", "c2"], viewport: viewport), "chat + 2 columns")
        #expect(model.screens[0].layout.ratio(of: "v") == 0.5, "the split inside a column is even too")
    }

    /// A window too narrow for three equal columns keeps the chat at its minimum; the columns beside it share the rest.
    @Test func narrowWindowKeepsTheChatAtItsMinimum() {
        let viewport = CGSize(width: 900, height: 800)
        let model = Self.model([
            LayoutColumn(id: "home", width: 0.2, root: .leaf("chat"), dock: Self.homeDock),
            LayoutColumn(id: "c1", width: 0.8, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.2, root: .leaf("p2")),
        ])
        model.equalize(screen: "s", viewportWidth: viewport.width)
        let widths = Self.widths(model, ["home", "c1", "c2"], viewport: viewport)
        let minimum = model.screens[0].layout.columns[0].minimumSize(style: model.style).width
        #expect(widths[0] >= minimum - 1, "\(widths)")
        Self.expectEqual(Array(widths.dropFirst()), "the strip columns")
    }

    /// A normal workspace of columns: the columns in view share the window equally.
    @Test func plainColumnsGetTheSameWidth() {
        let viewport = CGSize(width: 1600, height: 900)
        let model = Self.model([
            LayoutColumn(id: "c1", width: 0.33, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2")),
            LayoutColumn(id: "c3", width: 0.17, root: .leaf("p3")),
        ])
        #expect(model.equalize(screen: "s", viewportWidth: viewport.width) == .equalized)
        let widths = Self.widths(model, ["c1", "c2", "c3"], viewport: viewport)
        Self.expectEqual(widths, "three columns")
        #expect(abs(widths.reduce(0, +) - (viewport.width - 4 * model.style.stripGap)) <= 3, "they fill the window: \(widths)")
    }

    /// Two full-width columns beside the chat show one at a time: equalize brings both into the window beside the chat.
    @Test func fullWidthColumnsComeIntoViewBesideTheChat() {
        let viewport = CGSize(width: 1920, height: 1080)
        let model = Self.model([
            LayoutColumn(id: "home", width: 0.5, root: .leaf("chat"), dock: Self.homeDock),
            LayoutColumn(id: "c1", width: 1, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 1, root: .leaf("p2")),
        ], visible: ["chat", "p2"])
        #expect(model.equalize(screen: "s", viewportWidth: viewport.width) == .equalized)
        Self.expectEqual(Self.widths(model, ["home", "c1", "c2"], viewport: viewport), "chat + 2 full-width columns")
    }

    /// More columns than fit at their minimum width: the ones in view share the window; the rest get their width.
    @Test func tooManyColumnsShareByTheOnesInView() {
        let viewport = CGSize(width: 1200, height: 800)
        let columns = (1...8).map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.5, root: .leaf(PaneID("p\($0)"))) }
        let model = Self.model(columns, visible: ["p1", "p2"])
        model.equalize(screen: "s", viewportWidth: viewport.width)
        #expect(model.screens[0].layout.columns.allSatisfy { $0.width == 0.5 }, "two in view: each takes half")
    }

    /// A split-tree screen still equalizes its splits as before.
    @Test func splitScreenEqualizesItsSplits() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("h", axis: .horizontal, ratio: 0.8, a: .leaf("p1"), b: .leaf("p2"))))])
        model.followsDesignMetrics = false
        #expect(model.equalize(screen: "s", viewportWidth: 1200) == .equalized)
        #expect(model.screens[0].layout.ratio(of: "h") == 0.5)
    }

    /// Home's chat alone fills the screen: nothing to equalize, and its width stays for when a column opens beside it.
    @Test func loneChatHasNothingToEqualize() {
        let model = Self.model([LayoutColumn(id: "home", width: 0.4, root: .leaf("chat"), dock: Self.homeDock)])
        #expect(model.equalize(screen: "s", viewportWidth: 1400) == .nothingToEqualize)
        #expect(model.screens[0].layout.columns[0].width == 0.4)
    }

    /// A floating (overlay) dock covers the strip and shares no width: it keeps its own.
    @Test func floatingDockKeepsItsWidth() {
        let floating = DockColumn(edge: .left, mode: .overlay, role: .agentChat, isPinned: true)
        let model = Self.model([
            LayoutColumn(id: "home", width: 0.3, root: .leaf("chat"), dock: floating),
            LayoutColumn(id: "c1", width: 0.7, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.3, root: .leaf("p2")),
        ])
        model.equalize(screen: "s", viewportWidth: 1600)
        let columns = model.screens[0].layout.columns
        #expect(columns[0].width == 0.3)
        #expect(columns[1].width == 0.5 && columns[2].width == 0.5)
    }
}
