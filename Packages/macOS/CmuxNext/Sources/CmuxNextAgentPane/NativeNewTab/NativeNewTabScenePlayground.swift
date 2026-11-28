#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's Agent Pane scene (Prototypes/UiLayerHost `cmux-ui-agentpane --shoot DIR`, scene
/// `agent-new-tab`): the native New Tab page (``NativeNewTabView``) on a sample page (one open tab, a workspace, an
/// action and a history entry, as NativeNewTabViewTests' page), so a push to this module gets a before and after look
/// without an app build. Its actions do nothing.
@MainActor
public final class NativeNewTabScenePlayground {
    private var window: NSWindow?

    public init() {}

    /// Opens the window, or raises the open one.
    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    static func page() -> AgentPaneNewTab {
        let omnibar = AgentPaneOmnibar(
            tabs: [AgentPaneOmnibar.Tab(id: "t1", kind: .browser, title: "Vite guide", detail: "vite.dev/guide", workspace: "web")],
            workspaces: [AgentPaneOmnibar.Workspace(id: "w1", name: "app-efficiency")],
            actions: [AgentPaneOmnibar.Action(id: "toggleSidebar", title: "Toggle Sidebar", detail: "View", keycaps: ["⌘", "B"])],
            history: [AgentPaneOmnibar.Page(url: "https://news.ycombinator.com/", title: "Hacker News")]
        )
        return AgentPaneNewTab(kind: .agent, omnibar: omnibar)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "New Tab Playground"
        window.isReleasedWhenClosed = false
        let host = NativeNewTabView.hosted(NativeNewTabModel(page: Self.page(), actions: NativeNewTabActions()))
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.center()
        return window
    }
}
#endif
