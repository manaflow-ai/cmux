import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// R109 `tabs.barPosition` bottom: a pane's tab bar can sit below its
/// content. The border, ring and rounding then leave that footer out, and a
/// tab dropped on the footer joins the pane (as over a header).
@MainActor @Suite struct PaneChromeFooterTests {
    private final class FooterContent: NSView, PaneContentChrome {
        var paneHeaderHeight: CGFloat = 0
        var paneFooterHeight: CGFloat = 30
        var onPaneHeaderHeightChange: (() -> Void)?
        func setPaneContentCornerRadius(_ radius: CGFloat) {}
    }

    @Test func theRoundedAreaLeavesTheFooterOut() {
        let padded = CGRect(x: 4, y: 4, width: 200, height: 300)
        let rect = PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: 20, footerHeight: 30)
        #expect(rect == CGRect(x: 4, y: 24, width: 200, height: 250))
        #expect(PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: 0, footerHeight: 400).height == 0)
    }

    @Test func aDropOnTheFooterJoinsThePane() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let style = LayoutStyle()
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 200, y: 290), in: rect, footer: 30, style: style) == .center)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 200, y: 265), in: rect, footer: 30, style: style) == .bottom)
    }

    @Test func theHostTracesTheContentAboveTheFooter() {
        let host = PaneHostView(pane: "a", content: FooterContent())
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.chrome.frame = host.bounds
        host.applyShape(padding: 4, cornerRadius: 8)
        #expect(host.roundedRect == CGRect(x: 4, y: 4, width: 292, height: 162))
        #expect(host.footerHeight == 30)
        #expect(host.chrome.borderFrame.maxY <= 166.5)
    }

    /// The bottom dock band starts above a bottom tab bar (review of
    /// R109 part 2a): a tab dropped on the footer joins its pane, as the
    /// top band starts below a header (`topInset`).
    @Test func theBottomDockBandStartsAboveTheFooter() {
        let columns = [LayoutColumn(id: ColumnID("c0"), width: 1, root: .leaf(PaneID("p0")))]
        let geometry = ScreenGeometry.compute(.columns(columns), viewport: CGSize(width: 1000, height: 600), style: LayoutStyle(), scale: 2)
        let style = LayoutStyle()
        let target = { (y: CGFloat) in
            DropZoneGeometry.dockTarget(atView: CGPoint(x: 500, y: y), screen: "s", geometry: geometry, style: style, bottomInset: 30)
        }
        #expect(target(590) == nil, "on the footer: the pane takes the tab")
        #expect(target(565) == .newDock(screen: "s", edge: .bottom), "just above the footer")
    }
}
