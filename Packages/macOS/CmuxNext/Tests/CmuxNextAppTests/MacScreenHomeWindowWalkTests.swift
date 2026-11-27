import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import Testing

/// The Screen Sharing page as an accessibility client reaches it: from the window down, not the view alone. The
/// feature-flows walk (cmuxterm-hq synthetic-probes run 45598383119, 2026-11-25) opened the page from the File menu,
/// the palette and a pane's new-tab chevron, judged it the selected tab, and still read no `macScreen.home` in the
/// window's tree. Leo, 2026-11-13: "adding proper paths to screen share thru gui/command palette/wherever reasonable".
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenHomeWindowWalkTests {
    private func homeTree() -> DaemonTree {
        var tab = TabSnapshot(surface: 1, kind: .conversation, title: "Screen Sharing")
        tab.conversation = ConversationTabRef(page: InternalPageID.macScreen.rawValue, route: "home")
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "screen-walk", name: "Screen", screens: [screen])])
    }

    /// The views from the window's content view down to `view`, each with what the walk needs of it, for a failure.
    private static func chain(to view: NSView) -> String {
        var rows: [String] = []
        var current: NSView? = view
        while let at = current {
            let children = at.superview?.accessibilityChildren()?.count ?? -1
            rows.append("\(type(of: at)) hidden=\(at.isHidden) alpha=\(at.alphaValue) element=\(at.isAccessibilityElement()) "
                        + "parentAXChildren=\(children)")
            current = at.superview
        }
        return rows.joined(separator: "\n  ")
    }

    private static func homeView(under root: NSView) -> MacScreenHomeView? {
        if let home = root as? MacScreenHomeView { return home }
        for child in root.subviews { if let home = homeView(under: child) { return home } }
        return nil
    }

    @Test func theHomeIsInTheWindowsTreeWhenItsTabShows() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: homeTree())
        _ = services.windows.registry.apply { $0.openWindow(id: "screen-walk-window", workspaceIDs: ["screen-walk"]) }
        let controller = services.windows.makeController(for: try #require(services.windows.registry.value.window("screen-walk-window")))
        defer { controller.teardown(); controller.window?.close() }
        controller.state.showWorkspace("screen-walk")
        controller.showWorkspace(requested: "screen-walk")
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let home = try #require(Self.homeView(under: content), "no MacScreenHomeView under the window's content view")
        let identifiers = AccessibilityAudit().identifiers(under: window)
        #expect(identifiers.contains("macScreen.home"), "macScreen.home is not in the window's tree; the chain:\n  \(Self.chain(to: home))")
    }
}
