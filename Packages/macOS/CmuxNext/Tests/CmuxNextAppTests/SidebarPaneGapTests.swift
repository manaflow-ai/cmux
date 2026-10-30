import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The curved card leaves a small, unbroken strip of sidebar surface after a row. The resize line
/// stays in the titlebar band, while the flat style keeps its original edge-to-edge geometry.
@MainActor @Suite(.serialized) struct SidebarPaneGapTests {
    private func root(style: ChromeStyle) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        design.chromeStyle = style
        let model = SidebarModel()
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    @Test func curvedCardUsesTheNamedRowToCardGapAndKeepsTheBandPlain() throws {
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        let (window, root) = root(style: .card)
        defer { window.close() }

        let sidebar = root.sidebar
        let rowEnd = sidebar.frame.maxX + sidebar.paneReach - SidebarStyle.rowEdgeGap
        #expect(root.contentHost.frame.minX - rowEnd == SidebarStyle.rowToPaneGap)
        #expect(sidebar.paneReach > 0)
        let reachPoint = NSPoint(x: sidebar.bounds.maxX + sidebar.paneReach / 2, y: root.contentHost.frame.midY)
        #expect(sidebar.point(inside: reachPoint, with: nil))
        let line = sidebar.handle.convert(sidebar.handleFrameForTesting(), to: root)
        #expect(line.minY >= root.contentHost.frame.maxY - 0.01)
    }

    @Test func flatStyleKeepsTheSidebarAtTheCardEdgeAndItsFullHeightLine() throws {
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        let (window, root) = root(style: .flatSidebarLine)
        defer { window.close() }

        #expect(root.sidebar.paneReach == 0)
        #expect(root.contentHost.frame.minX == root.sidebar.frame.maxX)
        #expect(root.sidebar.handleFrameForTesting().minY == 0)
    }
}

private extension SidebarContainerView {
    func handleFrameForTesting() -> CGRect {
        handle.drawnLineFrame
    }
}
