import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-11 (msg 29542): "when we open and close sidebar, the animation of top buttons ... needs to be
/// better, rn when hiding sidebar, and my mouse is near left side of screen, it kinda hides and reappears". The
/// pointer over the sidebar holds the title bar buttons shown (its chrome reveal). Hiding the sidebar under that
/// pointer counted the hold as the top-left corner's hover: the collapsed band opened at full width instead of
/// leaving with the sidebar, then closed a delay after the slide, so the buttons stayed, jumped and left late.
/// Hiding ends the sidebar's hover: the band goes out with the sidebar, in the same frames.
@Suite(.closesItsWindows, .serialized)
@MainActor struct SidebarHideTitlebarMotionTests {
    private func shownRoot() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.width = 260
        let root = WindowRootView(sidebar: SidebarContainerView(model: model))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    @Test func hidingUnderThePointerOnTheSidebarTakesTheBandOutWithIt() {
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previous }
        let (window, root) = shownRoot()
        defer { window.close() }
        // The pointer rests on the sidebar: its chrome shows and holds the title bar buttons.
        root.sidebar.sidebarView.onChromeRevealChange?(true)
        #expect(root.titlebarReveal.state.holds > 0)
        // Toggle Sidebar from the keyboard, the pointer still where the sidebar was.
        root.sidebar.model.presentation = .hidden
        root.sidebar.apply()
        root.sidebarHidden = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        #expect(!root.collapsedBand.isOpen, "the band opened over the hidden sidebar for a hover that was the sidebar's")
        #expect(root.toolbarBand.presence == 0, "the band stayed at \(root.toolbarBand.presence) after the sidebar left")
        #expect(root.titlebarReveal.state.holds == 0, "the hidden sidebar's hover still holds the title bar buttons shown")
        // The slide that ends the hover (its chrome reveal off) changes nothing more.
        root.sidebar.sidebarView.onChromeRevealChange?(false)
        #expect(!root.collapsedBand.isOpen)
    }

    @Test func aHoverReportedByTheHiddenSidebarHoldsNothing() {
        let (window, root) = shownRoot()
        defer { window.close() }
        root.sidebar.model.presentation = .hidden
        root.sidebar.apply()
        root.sidebarHidden = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        // A tracking area of the sliding-out sidebar reports the pointer passing over it.
        root.sidebar.sidebarView.onChromeRevealChange?(true)
        #expect(root.titlebarReveal.state.holds == 0, "the hidden sidebar's hover held the title bar buttons")
        #expect(!root.collapsedBand.isOpen, "the hidden sidebar's hover opened the collapsed band")
    }
}
