import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A window ordered in keeps the keyboard where the focus model puts it (QA chrome-parity-v2-1, bug 1):
/// after a restart with a browser pane focused, the restored window came up before its panes' content,
/// with no first responder, and AppKit gave it its first key view, the sidebar's workspace list. The focus
/// model took that as the person's choice; Return then opened the workspace's rename field and the typed
/// command became the workspace's name.
@MainActor @Suite(.serialized)
struct ShellWindowInitialResponderTests {
    enum Order: CaseIterable {
        case orderBack, orderFrontRegardless, orderFront, makeKeyAndOrderFront
    }

    /// The app's window and root with its sidebar shown, not on screen yet, as a restore makes it.
    func hiddenWindow() -> (ShellWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
        let window = ShellWindow(contentRect: NSRect(x: 40, y: 40, width: 900, height: 600),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    func show(_ window: NSWindow, _ order: Order) {
        switch order {
        case .orderBack: window.orderBack(nil)
        case .orderFrontRegardless: window.orderFrontRegardless()
        case .orderFront: window.orderFront(nil)
        case .makeKeyAndOrderFront: window.makeKeyAndOrderFront(nil)
        }
        // AppKit's own key-view and key-window work of the ordering, then a turn of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Ordered in by every path `WindowActivation.show` takes, the window gives no view the keyboard
    /// that nobody asked for: the sidebar's workspace list, its first key view, stays without it.
    @Test(arguments: Order.allCases)
    func orderingInGivesTheSidebarNoKeyboard(_ order: Order) throws {
        let (window, root) = hiddenWindow()
        defer { window.orderOut(nil) }
        try #require(window.firstResponder === window, "a new window starts with no first responder")
        show(window, order)
        try #require(window.isVisible)
        let responder = window.firstResponder
        let inSidebar = (responder as? NSView)?.isDescendant(of: root.sidebar) == true
        #expect(!inSidebar, "ordered in by \(order), the window gave its first key view the keyboard: \(String(describing: responder))")
    }

    /// The sidebar still takes the keyboard when asked (Focus Sidebar, a click, its arrows): only the
    /// window's own pick while it is ordered in is refused.
    @Test func theSidebarStillTakesTheKeyboardWhenAsked() throws {
        let (window, root) = hiddenWindow()
        defer { window.orderOut(nil) }
        show(window, .orderFrontRegardless)
        root.sidebar.sidebarView.focusList()
        let responder = try #require(window.firstResponder as? NSView)
        #expect(responder.isDescendant(of: root.sidebar), "Focus Sidebar did not reach the list: \(responder)")
    }
}
