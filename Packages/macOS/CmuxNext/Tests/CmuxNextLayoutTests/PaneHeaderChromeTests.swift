import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// Content with a header (tab strip, browser toolbar): the border, ring and
/// rounding trace only the content area below it (dogfood nxdog9).
final class HeaderContent: NSView, PaneContentChrome {
    var paneHeaderHeight: CGFloat = 28 { didSet { onPaneHeaderHeightChange?() } }
    var onPaneHeaderHeightChange: (() -> Void)?
    private(set) var radius: CGFloat = -1
    func setPaneContentCornerRadius(_ radius: CGFloat) { self.radius = radius }
}

final class HeaderProvider: LayoutPaneContentProvider {
    var views: [PaneID: HeaderContent] = [:]
    func makeContentView(for pane: PaneID) -> NSView {
        let view = HeaderContent()
        views[pane] = view
        return view
    }
}

@Suite struct PaneHeaderGeometryTests {
    @Test func roundedAreaStartsBelowTheHeader() {
        let padded = CGRect(x: 4, y: 4, width: 200, height: 100)
        #expect(PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: 28) == CGRect(x: 4, y: 32, width: 200, height: 72))
        #expect(PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: 0) == padded)
        // A header taller than the pane leaves an empty rounded area, never a negative one.
        #expect(PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: 500).height == 0)
    }
}

extension LayoutDesignMetricsTests {
    @Test func borderAndCornersTraceOnlyTheContentBelowTheHeader() async throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(.leaf("a")))], activeScreenID: "s", focusedPane: nil)
        let provider = HeaderProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        view.frame = CGRect(origin: .zero, size: viewport)
        view.layoutSubtreeIfNeeded()

        try await withPaneChrome(PaneChromeOverrides(padding: 4, cornerRadius: 6, border: .subtle)) {
            try await waitUntil { view.context.hosts["a"]?.contentRect.minX == 4 }
            let host = try #require(view.context.hosts["a"])
            let content = try #require(provider.views["a"])
            // The padded rect still holds the whole view; only the content area rounds.
            #expect(host.contentRect == host.bounds.insetBy(dx: 4, dy: 4))
            #expect(host.content.superview?.layer?.cornerRadius == 0)
            #expect(content.radius == 6)
            #expect(host.roundedRect.minY == CGFloat(32))
            #expect(host.chrome.borderFrame == host.roundedRect)

            // The header shrinks (a browser toolbar hides): the border follows.
            content.paneHeaderHeight = 20
            #expect(host.chrome.borderFrame.minY == CGFloat(24))
        }
        withExtendedLifetime(provider) {}
    }
}
