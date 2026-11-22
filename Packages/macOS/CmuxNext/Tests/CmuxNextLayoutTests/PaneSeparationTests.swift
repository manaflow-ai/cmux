import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// `layout.paneSeparation` (R93): one choice for how panes are told apart.
/// Part of the serialized `LayoutDesignMetricsTests` suite because it
/// mutates `DesignSettings.shared`.
extension LayoutDesignMetricsTests {
    private var densityPadding: CGFloat { Metrics.density == .compact ? 2 : 4 }

    /// none: edge to edge, and no line at rest, on hover or while dragging.
    @Test func separationNoneDrawsNoBorderAndNoDividerAtAll() async {
        let model = LayoutModel()
        await withPaneChrome(PaneChromeOverrides(separation: PaneSeparation.none)) {
            let style = model.style
            #expect(style.panePadding == 0)
            #expect(!style.showsPaneBorder)
            #expect(!style.showsDividerLine)
            #expect(!style.showsDividerFeedback)
            #expect(style.paneCornerRadius == 0)
        }
    }

    /// dividers: edge to edge with one line between panes.
    @Test func separationDividersDrawsOnlyTheDividerLine() async {
        let model = LayoutModel()
        await withPaneChrome(PaneChromeOverrides(separation: .dividers)) {
            let style = model.style
            #expect(style.panePadding == 0)
            #expect(!style.showsPaneBorder)
            #expect(style.showsDividerLine)
            #expect(style.showsDividerFeedback)
        }
    }

    /// borders (the default, today's look): padded panes with a hairline.
    @Test func separationBordersIsTheDefaultLook() async {
        let model = LayoutModel()
        for overrides in [PaneChromeOverrides(), PaneChromeOverrides(separation: .borders)] {
            await withPaneChrome(overrides) {
                let style = model.style
                #expect(style.panePadding == densityPadding)
                #expect(style.showsPaneBorder)
                #expect(!style.showsDividerLine)
                #expect(style.showsDividerFeedback)
            }
        }
    }

    /// cards: padded rounded panes with no outline and no idle line.
    @Test func separationCardsKeepsGapsWithoutLines() async {
        let model = LayoutModel()
        await withPaneChrome(PaneChromeOverrides(separation: .cards)) {
            let style = model.style
            #expect(style.panePadding == densityPadding)
            #expect(style.paneCornerRadius > 0)
            #expect(!style.showsPaneBorder)
            #expect(!style.showsDividerLine)
            #expect(style.showsDividerFeedback)
        }
    }

    /// An explicit `layout.panePadding` still wins over the preset's gap.
    @Test func explicitPaddingRefinesTheSeparation() async {
        let model = LayoutModel()
        await withPaneChrome(PaneChromeOverrides(padding: 6, separation: PaneSeparation.none)) {
            #expect(model.style.panePadding == 6)
            #expect(!model.style.showsDividerFeedback)
        }
    }

    /// Without `layout.paneSeparation`, the legacy `layout.paneBorder` and
    /// padding keep meaning what they meant.
    @Test func legacyPaneBorderMapsOntoASeparation() {
        #expect(PaneSeparation.resolve(PaneChromeOverrides()) == .borders)
        #expect(PaneSeparation.resolve(PaneChromeOverrides(border: PaneBorderStyle.none)) == .cards)
        #expect(PaneSeparation.resolve(PaneChromeOverrides(padding: 0, border: PaneBorderStyle.none)) == .dividers)
        #expect(PaneSeparation.resolve(PaneChromeOverrides(border: PaneBorderStyle.none, separation: .borders)) == .borders)
    }

    /// Under none the resize handle stays a hit area with the resize
    /// cursor, but hovering or dragging it shows no line.
    @Test func dividerWithoutFeedbackStaysClearOnHover() throws {
        let view = DividerHandleView(kind: .split("s"), axis: .horizontal)
        view.frame = NSRect(x: 0, y: 0, width: 7, height: 200)
        view.showsIdleLine = false
        view.showsActiveLine = false
        view.setHovered(true)
        #expect((view.lineColor?.alpha ?? 0) == 0)
        view.showsActiveLine = true
        #expect((view.lineColor?.alpha ?? 0) > 0)
    }
}
