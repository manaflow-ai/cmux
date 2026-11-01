import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// At the sidebar's narrowest width the titlebar row still fits every control side by side: the
/// traffic lights, the toolbar band (sidebar toggle, Back, Forward) and the sidebar's + (New
/// Workspace). Lawrence 2026-10-30 (messages 17576, 17584): at the old 160 pt minimum Forward drew
/// over the +; "not remove glyph but just make min width of sidebar bigger". A width saved below
/// the new minimum (an existing user's) comes back clamped.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarMinimumWidthTitlebarTests {
    /// A window root in a titled, full-size-content window, as the app shows it.
    func root() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        settle(root)
        return (window, root)
    }

    func settle(_ root: WindowRootView) {
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
    }

    /// The gap between Forward's trailing edge and the +'s leading edge, in the root's coordinates.
    func gapBeforePlus(_ root: WindowRootView) -> CGFloat {
        let forward = root.toolbarBand.convert(root.toolbarBand.forwardButton.frame, to: root)
        let sidebarView = root.sidebar.sidebarView
        let plus = sidebarView.convert(sidebarView.newButton.frame, to: root)
        return plus.minX - forward.maxX
    }

    @Test func restoringAWidthBelowTheTitlebarMinimumClampsItSoNothingOverlaps() {
        let (window, root) = root()
        defer { window.close() }
        // An existing user's saved width at the old minimum.
        root.sidebar.restore(width: 160, presentation: .shown)
        settle(root)
        #expect(gapBeforePlus(root) >= Metrics.space2)
        #expect(root.sidebar.sidebarView.newButton.frame.maxX <= root.sidebar.sidebarView.bounds.maxX)
    }

    @Test func draggingToTheNarrowestWidthKeepsThePlusClearOfForward() {
        let (window, root) = root()
        defer { window.close() }
        let container = root.sidebar
        container.handleDrag(.began)
        // Narrower than any minimum, but above the drag's hide threshold.
        container.handleDrag(.changed(SidebarContainerView.hideThreshold + 1 - container.model.width))
        settle(root)
        #expect(!container.model.isHidden)
        #expect(gapBeforePlus(root) >= Metrics.space2)
    }

    @Test func theMinimumIsDerivedFromTheTitlebarControls() {
        let (window, root) = root()
        defer { window.close() }
        let sidebarView = root.sidebar.sidebarView
        let controls = sidebarView.titlebarLeadingReserve + SidebarStyle.toolbarButtonSize + Metrics.space3
        #expect(root.sidebar.model.minimumWidth == max(Metrics.sidebarMinWidth, controls))
    }

    @Test func thePriorityBellWidensTheMinimumAndStaysClearOfForward() {
        let (window, root) = root()
        defer { window.close() }
        let container = root.sidebar
        let before = container.model.minimumWidth
        container.sidebarView.showPriority(SidebarPriorityPanel(entries: []))
        #expect(container.model.minimumWidth >= before + SidebarStyle.toolbarButtonSize)
        container.restore(width: 160, presentation: .shown)
        settle(root)
        let forward = root.toolbarBand.convert(root.toolbarBand.forwardButton.frame, to: root)
        let bell = container.sidebarView.convert(container.sidebarView.priorityButton.frame, to: root)
        #expect(bell.minX - forward.maxX >= Metrics.space2)
        container.sidebarView.showPriority(nil)
        #expect(container.model.minimumWidth == before)
    }
}
