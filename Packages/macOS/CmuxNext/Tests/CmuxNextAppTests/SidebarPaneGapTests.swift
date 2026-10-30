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
        #expect(sidebar.hitTest(sidebar.convert(reachPoint, to: root)) != nil)
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

    @Test func rightSidebarHitTestsUseSuperviewCoordinatesAndRespectVisibility() throws {
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        let (window, root) = root(style: .card)
        defer { window.close() }
        root.sidebarSide = .right
        root.layoutSubtreeIfNeeded()

        let sidebar = root.sidebar
        #expect(sidebar.frame.minX > sidebar.bounds.width)
        let panePoint = NSPoint(x: 100, y: 100)
        #expect(sidebar.hitTest(panePoint) == nil)
        let inside = NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY)
        #expect(sidebar.hitTest(sidebar.convert(inside, to: root)) != nil)

        // A real child in the extended band catches double conversion of child coordinates.
        let reach = sidebar.visualPaneReach
        #expect(reach > 0)
        let target = NSView(frame: NSRect(x: -reach, y: 100, width: reach, height: 20))
        sidebar.addSubview(target)
        let point = sidebar.convert(NSPoint(x: -reach / 2, y: 110), to: root)
        #expect(sidebar.hitTest(point) === target)
        sidebar.isHidden = true
        #expect(sidebar.hitTest(point) == nil)
    }

    @Test func styleSwitchRemountsTheDividerAtTheNewSurfaceEdge() throws {
        let design = DesignSettings.shared
        let before = design.chromeStyle
        defer { design.chromeStyle = before }
        let (window, root) = root(style: .card)
        defer { window.close() }

        let cardLineX = root.sidebar.handleLineFrameInRoot().midX
        let cardReach = root.sidebar.paneReach
        #expect(cardReach > 0)

        design.chromeStyle = .flatSidebarLine
        root.applyMainPane()
        root.sidebar.apply()
        root.layoutSubtreeIfNeeded()

        let flatLineX = root.sidebar.handleLineFrameInRoot().midX
        #expect(cardLineX - flatLineX == cardReach)
        #expect(flatLineX == root.sidebar.frame.maxX)
    }
}

private extension SidebarContainerView {
    func handleFrameForTesting() -> CGRect {
        handle.drawnLineFrame
    }

    func handleLineFrameInRoot() -> CGRect {
        handle.convert(handleFrameForTesting(), to: superview)
    }
}
