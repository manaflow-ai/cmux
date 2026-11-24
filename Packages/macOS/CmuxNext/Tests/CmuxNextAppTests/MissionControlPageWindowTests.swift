import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowserHost
import CmuxNextPages
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/48535: Mission Control (four fingers up) with cmux NEXT in front showed
/// none of the other windows; Cmd-H on cmux brought them back. A Chromium page's input window (`CefNSWindow`, a child
/// of the cmux window that draws nothing: the page draws in the cmux window's layers) stays with its page, and a page
/// waiting off screen (the New Tab spare in `PageOffscreenParking`, a hidden agent page in its render window) keeps it
/// 100 000 points outside the cmux window. Mission Control laid that window out too, fit a layout 100 000 points wide on
/// the screen, and every window shrank to nothing. Real AppKit windows ordered on screen; the stand-in page window
/// carries the fork's embedded flag.
@MainActor @Suite(.serialized, .closesItsWindows) struct MissionControlPageWindowTests {
    final class StandInPageWindow: NSWindow {
        var embedded = true
        @objc dynamic func isEmbeddedInParentView() -> Bool { embedded }
    }

    private static let content = CGRect(x: 200, y: 200, width: 800, height: 500)

    private func shellWindow() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: Self.content, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(origin: .zero, size: Self.content.size))
        window.orderFrontRegardless()
        return window
    }

    /// A page window where the New Tab spare's page waits: `PageOffscreenParking`'s frame, in screen coordinates.
    private func parkedPage(in parent: NSWindow, behavior: NSWindow.CollectionBehavior = []) -> StandInPageWindow {
        let parked = PageOffscreenParking.frame(in: parent.contentView?.bounds ?? .zero, size: nil)
        let page = StandInPageWindow(contentRect: parent.convertToScreen(parked), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        page.collectionBehavior = behavior
        return page
    }

    @Test func aParkedPageWindowInTheCmuxWindowStaysOutOfMissionControl() {
        let window = shellWindow()
        let page = parkedPage(in: window)
        #expect(page.frame.maxX < window.frame.minX - 90_000)
        window.addChildWindow(page, ordered: .above)
        #expect(page.parent === window && page.isVisible)
        #expect(page.collectionBehavior.contains(.transient))
        page.close()
        window.close()
    }

    /// Chromium may have given the window a Mission Control behavior of its own: AppKit allows one of
    /// managed, transient and stationary at a time, so it is replaced; full screen and Spaces behaviors stay.
    @Test func aPageWindowWithItsOwnExposeBehaviorBecomesTransientAndKeepsTheRest() {
        let window = shellWindow()
        let page = parkedPage(in: window, behavior: [.managed, .fullScreenAuxiliary])
        window.addChildWindow(page, ordered: .above)
        #expect(page.collectionBehavior.contains(.transient))
        #expect(!page.collectionBehavior.contains(.managed))
        #expect(page.collectionBehavior.contains(.fullScreenAuxiliary))
        // The fork re-adds a page window on every reattach: nothing changes the second time.
        page.orderOut(nil)
        window.removeChildWindow(page)
        window.addChildWindow(page, ordered: .above)
        #expect(page.collectionBehavior == [.transient, .fullScreenAuxiliary])
        page.close()
        window.close()
    }

    /// A page window that is not embedded draws its own page (a page in a window of its own): Mission Control keeps it.
    @Test func aPageWindowThatIsNotEmbeddedKeepsItsBehavior() {
        let window = shellWindow()
        let page = parkedPage(in: window)
        page.embedded = false
        window.addChildWindow(page, ordered: .above)
        #expect(!page.collectionBehavior.contains(.transient))
        page.close()
        window.close()
    }

    /// A hidden tab an agent drives renders in a render window off every screen; its page window goes with it.
    @Test func aPageWindowInAnAgentRenderWindowStaysOutOfMissionControl() {
        _ = NSApplication.shared
        let panel = AgentRenderPanel(viewport: CGSize(width: 800, height: 500), screens: NSScreen.screens.map(\.frame),
                                     privateCalls: AgentRenderWindows().privateCalls)
        panel.orderBack(nil)
        let page = StandInPageWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        panel.addChildWindow(page, ordered: .above)
        #expect(page.parent === panel)
        #expect(page.collectionBehavior.contains(.transient))
        page.close()
        panel.finish()
    }
}
