import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// With the sidebar open, every control in its titlebar row shows at rest: the sidebar toggle, Back,
/// Forward and the + (New Workspace) button (Lawrence 2026-10-28 message 15460: "when sidebar is open,
/// this stuff should show by default (+ button too) ... if sidebar is open, all the stuff should
/// show"). Only Show Sidebar Controls Only on Hover (`sidebar.controlsOnHover`) hides them until the
/// pointer is over the sidebar. With the sidebar hidden, `window.titlebarButtons` still decides (hover
/// by default: the corner hover opens the collapsed band, cx-fi0i).
@MainActor @Suite(.serialized) struct SidebarOpenTitlebarControlsTests {
    /// A window root in a titled, full-size-content window, as the app shows it.
    func root(sidebarHidden: Bool) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        if sidebarHidden { model.presentation = .hidden }
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.sidebar.isHidden = sidebarHidden
        root.sidebarHidden = sidebarHidden
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    /// Runs `body` with the given settings, then puts the shared settings back.
    func with(titlebarButtons: TitlebarButtonsMode = .hover, controlsOnHover: Bool = false, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saved = (design.titlebarButtons, design.sidebarSections)
        defer { (design.titlebarButtons, design.sidebarSections) = saved }
        design.titlebarButtons = titlebarButtons
        design.sidebarSections.controlsOnHover = controlsOnHover
        try body()
    }

    func titlebarButtons(_ root: WindowRootView) -> [NSView] {
        [root.toolbarBand.sidebarToggle, root.toolbarBand.backButton, root.toolbarBand.forwardButton]
    }

    @Test func sidebarOpenShowsEveryTitlebarControlWithThePointerAway() {
        with {
            let (window, root) = root(sidebarHidden: false)
            defer { window.close() }
            root.applyTitlebarButtonsMode()
            root.titlebarReveal.setPointerInside(false)
            #expect(root.titlebarReveal.isRevealed)
            for button in titlebarButtons(root) { #expect(button.alphaValue == 1) }
            #expect(root.sidebar.sidebarView.newButton.alphaValue == 1)
        }
    }

    @Test func hidingTheSidebarHidesTheButtonsAtRestAndShowingItBringsThemBack() {
        with {
            let (window, root) = root(sidebarHidden: false)
            defer { window.close() }
            root.titlebarReveal.setPointerInside(false)
            root.sidebarHidden = true
            #expect(!root.titlebarReveal.isRevealed)
            root.sidebarHidden = false
            #expect(root.titlebarReveal.isRevealed)
            for button in titlebarButtons(root) { #expect(button.alphaValue == 1) }
        }
    }

    @Test func sidebarHiddenKeepsTheHoverDefault() {
        with {
            let (window, root) = root(sidebarHidden: true)
            defer { window.close() }
            root.applyTitlebarButtonsMode()
            root.titlebarReveal.setPointerInside(false)
            #expect(!root.titlebarReveal.isRevealed)
        }
    }

    @Test func controlsOnHoverHidesThemAtRestWithTheSidebarOpen() {
        with(controlsOnHover: true) {
            let (window, root) = root(sidebarHidden: false)
            defer { window.close() }
            root.applyTitlebarButtonsMode()
            root.titlebarReveal.setPointerInside(false)
            #expect(!root.titlebarReveal.isRevealed)
            root.titlebarReveal.setPointerInside(true)
            #expect(root.titlebarReveal.isRevealed)
        }
    }

    @Test func titlebarButtonsAlwaysShowsThemWithTheSidebarHidden() {
        with(titlebarButtons: .always) {
            let (window, root) = root(sidebarHidden: true)
            defer { window.close() }
            root.applyTitlebarButtonsMode()
            root.titlebarReveal.setPointerInside(false)
            #expect(root.titlebarReveal.isRevealed)
        }
    }
}
