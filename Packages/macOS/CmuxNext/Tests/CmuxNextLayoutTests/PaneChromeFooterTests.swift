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
}
