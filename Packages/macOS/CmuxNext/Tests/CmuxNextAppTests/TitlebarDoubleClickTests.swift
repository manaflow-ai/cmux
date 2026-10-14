import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// A double-click on empty titlebar space runs the user's titlebar action once (Leo, cosmic-gray
/// 2026-10-13). The press reached both the sidebar header's `mouseDown` and the window's
/// `sendEvent`, which each zoomed: the window bounced and ended where it started.
@MainActor struct TitlebarDoubleClickTests {
    /// The app's window and root, sidebar shown, on the main screen and not zoomed.
    func shownRoot() throws -> (ShellWindow, WindowRootView) {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main, "zooming needs a screen")
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = ShellWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 900, height: 600), display: false)
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    /// The sidebar header's first window point that is empty titlebar space (the policy moves the
    /// window there) and is the sidebar's own: the top-left area Leo double-clicked.
    func sidebarHeaderPoint(in window: NSWindow, root: WindowRootView) throws -> CGPoint {
        let sidebar = root.sidebar.convert(root.sidebar.bounds, to: nil)
        let y = sidebar.maxY - Metrics.titlebarHeight / 2
        let frameView = try #require(window.contentView?.superview)
        let point = stride(from: sidebar.minX + 1, to: sidebar.maxX, by: 2).lazy.map { CGPoint(x: $0, y: y) }.first { point in
            guard TitlebarDragPolicy.decide(at: point, in: window) == .movesWindow,
                  let hit = frameView.hitTest(frameView.convert(point, from: nil)) else { return false }
            return hit.isDescendant(of: root.sidebar)
        }
        return try #require(point, "the sidebar header has empty titlebar space")
    }

    func press(at point: CGPoint, clicks: Int, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    @Test(.enabled(if: NSScreen.main != nil)) func aDoubleClickOnTheSidebarHeaderZoomsTheWindowOnce() throws {
        // The host's own titlebar setting does not decide the test: zoom, in this process only.
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(arguments.merging(["AppleActionOnDoubleClick": "Maximize"]) { $1 }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let (window, root) = try shownRoot()
        defer { window.close() }
        let before = window.frame
        #expect(!window.isZoomed)

        window.sendEvent(try press(at: sidebarHeaderPoint(in: window, root: root), clicks: 2, in: window))

        #expect(window.isZoomed, "zoomed twice: the window went back to \(window.frame), from \(before)")
        #expect(window.frame != before)
    }
}
