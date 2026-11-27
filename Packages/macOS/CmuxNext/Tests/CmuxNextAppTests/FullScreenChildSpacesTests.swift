import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Empty cmux window over a full screen transition (user, 2026-11-25): a background cmux window drew over another
/// window's full screen enter and exit, about 0.6 s each. It was parked in ANOTHER app's full screen Space (Chrome's, on
/// the same display), where it had followed a child panel declared `.fullScreenAuxiliary`: AppKit keeps a child on its
/// parent's Space, and the child may join a full screen Space. A main window's child panels now carry that behavior
/// only while the window itself is in full screen.
///
/// Real ShellWindows, their real `addChildWindow` override and the real overlay host panel. A window's full screen
/// transition is AppKit's will/did enter and exit notifications, which a test posts to a private center for its own
/// window with the app's transition tracker on that center (`LiveResizeWindows`, as `LiveResizePerWindowTests`); a
/// failed one is the call the window's delegate makes (`Motion.fullScreenTransitionFailed`).
@MainActor @Suite(.serialized, .closesItsWindows) struct FullScreenChildSpacesTests {
    /// `body` runs with the app's transition tracker on a private center.
    private func tracked(_ body: (NotificationCenter) -> Void) {
        let center = NotificationCenter()
        let app = LiveResizeWindows.shared
        LiveResizeWindows.shared = LiveResizeWindows(center: center)
        defer { LiveResizeWindows.shared = app }
        body(center)
    }

    private func shellWindow() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        return window
    }

    /// The window's overlay host panel, showing a toast (as a toast or a page's overlay shows in normal use).
    private func showToast(on window: NSWindow) -> WindowOverlayHost {
        let host = WindowOverlayHost.host(for: window)
        _ = host.present(NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20)),
                         options: OverlayOptions(kind: .toast, anchor: CGRect(x: 10, y: 10, width: 10, height: 10), passesThroughClicks: true))
        return host
    }

    private func panel(_ behavior: NSWindow.CollectionBehavior) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: -3000, y: -3000, width: 100, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = behavior
        return panel
    }

    private func auxiliary(_ child: NSWindow) -> Bool { child.collectionBehavior.contains(.fullScreenAuxiliary) }

    private func post(_ name: Notification.Name, _ window: NSWindow, on center: NotificationCenter) {
        center.post(name: name, object: window)
    }

    /// The overlay host panel of a window that is not in full screen cannot join a full screen Space, so it cannot take
    /// its window into one. Its other behaviors stay.
    @Test func aChildPanelOfAWindowedWindowCannotJoinAFullScreenSpace() {
        tracked { _ in
            let window = shellWindow()
            let host = showToast(on: window)
            #expect(host.panel.parent === window)
            #expect(!auxiliary(host.panel), "a windowed cmux window's overlay panel may join another app's full screen Space")
            #expect(host.panel.collectionBehavior.isSuperset(of: [.transient, .ignoresCycle]))
            window.close()
        }
    }

    /// Two main windows of one app, both with their overlay panel attached: while A enters and sits in full screen, B
    /// (windowed, behind it) keeps a panel that cannot join A's full screen Space; A's own panel goes with A, and
    /// leaves it with A.
    @Test func aSecondWindowsPanelStaysOutOfTheFirstWindowsFullScreen() {
        tracked { center in
            let a = shellWindow(), b = shellWindow()
            let hostA = showToast(on: a), hostB = showToast(on: b)
            #expect(hostA.panel.parent === a && hostB.panel.parent === b)
            post(NSWindow.willEnterFullScreenNotification, a, on: center)
            #expect(auxiliary(hostA.panel), "A's panel must go with A into its full screen Space")
            #expect(!auxiliary(hostB.panel), "B's panel could join A's full screen Space and take B with it")
            post(NSWindow.didEnterFullScreenNotification, a, on: center)
            #expect(auxiliary(hostA.panel) && !auxiliary(hostB.panel))
            post(NSWindow.willExitFullScreenNotification, a, on: center)
            #expect(auxiliary(hostA.panel), "A's panel stays with A while it leaves")
            post(NSWindow.didExitFullScreenNotification, a, on: center)
            #expect(!auxiliary(hostA.panel) && !auxiliary(hostB.panel))
            b.close()
            a.close()
        }
    }

    /// Auxiliary from willEnter (before AppKit moves the window to its new Space) until didExit; a failed enter (the
    /// delegate's `windowDidFailToEnterFullScreen`, AppKit posts nothing for it) leaves the window windowed.
    @Test func aChildPanelFollowsItsWindowAcrossTheTransitions() {
        tracked { center in
            let window = shellWindow()
            let child = panel([.fullScreenAuxiliary, .transient, .ignoresCycle])
            window.addChildWindow(child, ordered: .above)
            #expect(!auxiliary(child))

            post(NSWindow.willEnterFullScreenNotification, window, on: center)
            #expect(auxiliary(child), "the child must be auxiliary before AppKit moves its window into the new full screen Space")
            Motion.fullScreenTransitionFailed(window)
            #expect(!auxiliary(child), "a failed enter leaves the window windowed")

            post(NSWindow.willEnterFullScreenNotification, window, on: center)
            post(NSWindow.didEnterFullScreenNotification, window, on: center)
            post(NSWindow.willExitFullScreenNotification, window, on: center)
            #expect(auxiliary(child), "the child stays with its window while it leaves")
            post(NSWindow.didExitFullScreenNotification, window, on: center)
            #expect(!auxiliary(child))
            #expect(child.collectionBehavior.isSuperset(of: [.transient, .ignoresCycle]))
            child.close()
            window.close()
        }
    }

    /// A child added while the window enters full screen is auxiliary at once; one that never declared the behavior (a
    /// Chromium page's input window) never gets it.
    @Test func aChildAddedWhileEnteringJoinsAndAnUndeclaredChildIsLeftAlone() {
        tracked { center in
            let window = shellWindow()
            let first = panel([.fullScreenAuxiliary, .transient])
            window.addChildWindow(first, ordered: .above)
            post(NSWindow.willEnterFullScreenNotification, window, on: center)
            let late = panel([.fullScreenAuxiliary, .transient])
            let page = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            window.addChildWindow(late, ordered: .above)
            window.addChildWindow(page, ordered: .above)
            #expect(auxiliary(first) && auxiliary(late))
            #expect(!auxiliary(page))
            post(NSWindow.didEnterFullScreenNotification, window, on: center)
            post(NSWindow.willExitFullScreenNotification, window, on: center)
            post(NSWindow.didExitFullScreenNotification, window, on: center)
            #expect(!auxiliary(first) && !auxiliary(late))
            #expect(!auxiliary(page))
            for child in [first, late, page] { child.close() }
            window.close()
        }
    }
}
