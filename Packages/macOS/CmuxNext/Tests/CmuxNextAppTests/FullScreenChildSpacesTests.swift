import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Empty cmux window over a full screen transition (user, 2026-11-25): a background cmux window drew over another
/// window's full screen enter and exit, about 0.6 s each. It was parked in ANOTHER app's full screen Space (Chrome's, on
/// the same display), where it had followed a child panel declared `.fullScreenAuxiliary`: AppKit keeps a child on its
/// parent's Space, and the child may join a full screen Space. A main window's child panels now carry that behavior
/// only while the window itself is in full screen, across AppKit's will/did enter and exit callbacks. Real ShellWindow
/// and panel classes; the transition calls are the ones the window's delegate (`WindowController+FullScreen`) makes.
@MainActor @Suite(.serialized, .closesItsWindows) struct FullScreenChildSpacesTests {
    private func shellWindow() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        return window
    }

    private func auxiliary(_ child: NSWindow) -> Bool { child.collectionBehavior.contains(.fullScreenAuxiliary) }

    /// The overlay host panel of a window that is not in full screen cannot join a full screen Space, so it cannot take
    /// its window into one. Its other behaviors stay.
    @Test func aChildPanelOfAWindowedWindowCannotJoinAFullScreenSpace() {
        let window = shellWindow()
        let host = WindowOverlayHost.host(for: window)
        _ = host.present(NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20)),
                         options: OverlayOptions(kind: .toast, anchor: CGRect(x: 10, y: 10, width: 10, height: 10), passesThroughClicks: true))
        #expect(host.panel.parent === window)
        #expect(!auxiliary(host.panel), "a windowed cmux window's overlay panel may join another app's full screen Space")
        #expect(host.panel.collectionBehavior.isSuperset(of: [.transient, .ignoresCycle]))
        window.close()
    }

    private func panel(_ behavior: NSWindow.CollectionBehavior) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: -3000, y: -3000, width: 100, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = behavior
        return panel
    }

    /// Across a full screen enter and exit: auxiliary from willEnter (before AppKit moves the window to its new Space)
    /// until didExit. (No didEnter here: without a real transition the style mask never says `.fullScreen`, which is
    /// what keeps the children auxiliary in full screen in the app.)
    @Test func aChildPanelFollowsItsWindowAcrossTheTransitions() {
        let window = shellWindow()
        let child = panel([.fullScreenAuxiliary, .transient, .ignoresCycle])
        window.addChildWindow(child, ordered: .above)
        #expect(!auxiliary(child))

        ChildWindowSpaces.willEnterFullScreen(window)
        #expect(auxiliary(child), "the child must be auxiliary before AppKit moves its window into the new full screen Space")
        ChildWindowSpaces.didFailToEnterFullScreen(window)
        #expect(!auxiliary(child), "a failed enter leaves the window windowed")

        ChildWindowSpaces.willEnterFullScreen(window)
        #expect(auxiliary(child))
        ChildWindowSpaces.willExitFullScreen(window)
        #expect(auxiliary(child), "the child stays with its window while it leaves")
        ChildWindowSpaces.didExitFullScreen(window)
        #expect(!auxiliary(child))
        #expect(child.collectionBehavior.isSuperset(of: [.transient, .ignoresCycle]))
        child.close()
        window.close()
    }

    /// A child added while the window enters full screen is auxiliary at once; one that never declared the behavior (a
    /// Chromium page's input window) never gets it.
    @Test func aChildAddedWhileEnteringJoinsAndAnUndeclaredChildIsLeftAlone() {
        let window = shellWindow()
        let first = panel([.fullScreenAuxiliary, .transient])
        window.addChildWindow(first, ordered: .above)
        ChildWindowSpaces.willEnterFullScreen(window)
        let late = panel([.fullScreenAuxiliary, .transient])
        let page = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        window.addChildWindow(late, ordered: .above)
        window.addChildWindow(page, ordered: .above)
        #expect(auxiliary(first) && auxiliary(late))
        #expect(!auxiliary(page))
        ChildWindowSpaces.willExitFullScreen(window)
        ChildWindowSpaces.didExitFullScreen(window)
        #expect(!auxiliary(first) && !auxiliary(late))
        #expect(!auxiliary(page))
        for child in [first, late, page] { child.close() }
        window.close()
    }
}
