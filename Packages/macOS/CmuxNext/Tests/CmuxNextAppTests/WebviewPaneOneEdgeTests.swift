import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextPages
import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// One surface edge (Leo 2026-10-13, the New Tab page on cosmic-gray): a webview pane showed the
/// curved main pane's rounded card and, a few points inside it, a second faint rounded box: the
/// pane's own content area, clipped to the pane corner radius and outlined by the pane border.
/// The page itself draws no frame. Between a webview and the window exactly one layer draws an
/// edge, the main pane card, as for any other pane.
@MainActor @Suite(.serialized) struct WebviewPaneOneEdgeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Hands the layout one pane: the app's pane view (tab strip and content host) showing `content`.
    final class Provider: LayoutPaneContentProvider {
        let content: NSView
        private(set) var pane: PaneContentView?

        init(content: NSView) { self.content = content }

        func makeContentView(for pane: PaneID) -> NSView {
            let view = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("tab"), title: "New Tab")]),
                                       reveal: LaunchReveal(deadline: .zero))
            view.show(content)
            self.pane = view
            return view
        }
    }

    /// A window as the app builds it: the sidebar, the curved main pane card, and one workspace
    /// whose single pane shows `content`.
    final class Rig {
        let window: NSWindow
        let root: WindowRootView
        let layout: LayoutRootView
        let provider: Provider

        init(content: NSView) {
            _ = NSApplication.shared
            provider = Provider(content: content)
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))],
                                    activeScreenID: "s", focusedPane: "p1")
            layout = LayoutRootView(model: model, contentProvider: provider)
            root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentView = root
            root.show(layout)
            for _ in 0..<2 {
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
            }
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }

        /// Every layer between `content` (itself included) and the window that draws a surface
        /// edge: a visible border, or a corner radius that clips. The pane border lives in the
        /// layout's overlay plane, not in the ancestor chain, so it is added when it shows.
        func edges(of content: NSView) -> [String] {
            var found: [String] = []
            var view: NSView? = content
            while let current = view {
                if let layer = current.layer, !current.isHidden {
                    if layer.borderWidth > 0 && layer.opacity > 0 {
                        found.append("\(type(of: current)) border \(layer.borderWidth)")
                    } else if layer.cornerRadius > 0 && layer.masksToBounds {
                        found.append("\(type(of: current)) radius \(layer.cornerRadius)")
                    }
                }
                view = current.superview
            }
            let host = layout.screenViews["s"]?.displayedHosts.first
            if host?.chrome.showsBorder == true || layout.model.style.showsPaneBorder {
                found.append("PaneOverlayView border")
            }
            return found
        }
    }

    /// The single edge is the main pane card's, at the main pane's radius.
    private func expectOneEdge(_ rig: Rig, content: NSView, _ what: String) throws {
        try #require(Metrics.mainPaneCurved, "the curved main pane is on by default")
        try #require(content.isDescendant(of: rig.root.contentHost), "\(what) is hosted in the main pane")
        let edges = rig.edges(of: content)
        #expect(edges.count == 1, "\(what): one surface edge between the page and the window, got \(edges)")
        #expect(edges.first?.hasPrefix("MainPaneCardView") == true, "\(what): the edge is the main pane card's, got \(edges)")
        #expect(rig.root.contentHost.layer?.cornerRadius == Metrics.mainPaneCornerRadius)
    }

    private static func page(_ html: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "one-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data(html.utf8).write(to: file)
        return file
    }

    @Test func theNewTabPageHasOneSurfaceEdge() throws {
        let file = try Self.page("<html><body></body></html>")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent))
        let newTab = try #require(AgentPaneView(model: model, source: .bundled(file)))
        let rig = Rig(content: newTab)
        defer { rig.tearDown() }
        try expectOneEdge(rig, content: newTab, "New Tab")
    }

    /// A first-party page pane (History, Settings, App Store, Activity) is a `PageWebView`.
    @Test func aPagePaneHasOneSurfaceEdge() throws {
        let file = try Self.page("<html><body></body></html>")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let descriptor = PageDescriptor(id: "test.one-edge", resource: "one-edge", namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: file.deletingLastPathComponent(), routes: []))
        let rig = Rig(content: page)
        defer { rig.tearDown() }
        try expectOneEdge(rig, content: page, "page pane")
    }

    /// A webview pane's edges are any other pane's: a plain view (a terminal's place) gets the same one.
    @Test func aWebviewPaneHasTheEdgesOfAnyOtherPane() throws {
        let file = try Self.page("<html><body></body></html>")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let newTab = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent)),
                                                source: .bundled(file)))
        let web = Rig(content: newTab)
        defer { web.tearDown() }
        let plain = NSView()
        let other = Rig(content: plain)
        defer { other.tearDown() }
        #expect(web.edges(of: newTab) == other.edges(of: plain))
    }
}
