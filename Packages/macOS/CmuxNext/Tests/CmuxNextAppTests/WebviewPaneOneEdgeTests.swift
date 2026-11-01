import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextPages
import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

extension MainPaneGutterSuites {
    /// One surface edge (Leo 2026-10-13, the New Tab page on cosmic-gray): a webview pane showed the
    /// curved main pane's rounded card and, a few points inside it, a second faint rounded box: the
    /// pane's own content area, clipped to the pane corner radius and outlined by the pane border.
    /// The page itself draws no frame. Between a webview and the window exactly one layer draws an
    /// edge, the main pane card, as for any other pane.
    ///
    /// One outline at the window edge (Leo 2026-10-13, an agent chat pane over wallpaper art): at the
    /// window's top-right corner the window's own rounded edge showed and, a gutter inside it, a second
    /// rounded outline: the main pane card stood off the window edge, and the chrome shade over that
    /// gutter stepped darker than the card over the art. The window's frame is an edge too: with the
    /// flush opt-in (Debug Settings gutter 0) the main pane takes the window's own edge and corners
    /// where it meets the window, so one outline shows. The default keeps today's 6 pt gutter.
    @MainActor struct WebviewPaneOneEdgeTests {
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

            /// The window's room theme, with `art` as its wallpaper when given.
            let room = ThemeScope(level: .room)

            init(content: NSView, art: BackdropArt? = nil, sidebarSide: SidebarSide = .left, sidebarHidden: Bool = false) {
                _ = NSApplication.shared
                provider = Provider(content: content)
                let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))],
                                        activeScreenID: "s", focusedPane: "p1")
                layout = LayoutRootView(model: model, contentProvider: provider)
                let sidebarModel = SidebarModel()
                if sidebarHidden { sidebarModel.presentation = .hidden }
                root = WindowRootView(sidebar: SidebarContainerView(model: sidebarModel))
                window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.titlebarAppearsTransparent = true
                if let art { room.pinBackdrop(.selection(.art(art))) }
                room.root(root)
                room.adopt(window)
                window.contentView = root
                root.sidebarSide = sidebarSide
                if sidebarHidden {
                    root.sidebar.isHidden = true
                    root.sidebarHidden = true
                }
                root.themeDidChange()
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

            /// The window edges the main pane meets: every edge but the sidebar's while it shows.
            var windowEdges: [NSRectEdge] {
                let all: [NSRectEdge] = [.maxY, .maxX, .minY, .minX]
                if root.sidebarHidden { return all }
                return all.filter { $0 != (root.sidebarSide == .left ? .minX : .maxX) }
            }

            /// Every rounded outline where the main pane meets the window's `edge`, the window's own
            /// frame included: a card standing off the edge (a gutter step), a stroke on the card, a
            /// card corner that is not the window's, and a chrome shade band along the edge.
            func outlines(at edge: NSRectEdge) -> [String] {
                let windowRadius = CEFClipShape.windowCornerRadius(window)
                var found = ["window frame radius \(windowRadius)"]
                let bounds = root.bounds, card = root.contentHost.frame
                let gap: CGFloat = switch edge {
                case .maxY: bounds.maxY - card.maxY
                case .maxX: bounds.maxX - card.maxX
                case .minY: card.minY - bounds.minY
                default: card.minX - bounds.minX
                }
                if gap > 0.25 { found.append("card \(gap) pt inside the window edge") }
                if let layer = root.contentHost.layer {
                    if layer.borderWidth > 0 { found.append("card border \(layer.borderWidth)") }
                    if layer.masksToBounds, layer.cornerRadius > 0, abs(layer.cornerRadius - windowRadius) > 0.25 {
                        found.append("card corner \(layer.cornerRadius) inside the window's \(windowRadius)")
                    }
                }
                // Half a point inside the window edge, along the pane's middle.
                let probe: CGPoint = switch edge {
                case .maxY: CGPoint(x: card.midX, y: bounds.maxY - 0.5)
                case .maxX: CGPoint(x: bounds.maxX - 0.5, y: card.midY)
                case .minY: CGPoint(x: card.midX, y: bounds.minY + 0.5)
                default: CGPoint(x: bounds.minX + 0.5, y: card.midY)
                }
                let shade = root.mainPaneShade.layer?.sublayers?.lazy.compactMap { $0 as? CAShapeLayer }.first
                if let shade, let path = shade.path, path.contains(probe, using: .evenOdd),
                   let fill = shade.fillColor, fill.alpha > 0 {
                    found.append("chrome shade band \(fill.alpha)")
                }
                return found
            }
        }

        /// The single edge is the main pane card's rounded clip.
        private func expectOneEdge(_ rig: Rig, content: NSView, _ what: String) throws {
            try #require(Metrics.mainPaneCurved, "the curved main pane is on by default")
            try #require(content.isDescendant(of: rig.root.contentHost), "\(what) is hosted in the main pane")
            let edges = rig.edges(of: content)
            #expect(edges.count == 1, "\(what): one surface edge between the page and the window, got \(edges)")
            #expect(edges.first?.hasPrefix("MainPaneCardView") == true, "\(what): the edge is the main pane card's, got \(edges)")
            #expect((rig.root.contentHost.layer?.cornerRadius ?? 0) > 0, "\(what): the card is rounded")
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

        /// With the Debug Settings flush opt-in (gutter 0), where the main pane meets the window (top,
        /// trailing, bottom, and the leading edge with the sidebar hidden) exactly one rounded outline
        /// shows, the window's own, over wallpaper art and on an opaque theme, with the sidebar on
        /// either side or hidden.
        @Test(arguments: [BackdropArt?.some(.friedrichForestMoonlight), nil])
        func whereThePaneMeetsTheWindowOneOutlineShows(art: BackdropArt?) throws {
            try #require(Metrics.mainPaneCurved, "the curved main pane is on by default")
            try MainPaneGutterSuites.withGutter(0) {
                for (side, hidden) in [(SidebarSide.left, false), (.right, false), (.left, true)] {
                    let rig = Rig(content: NSView(), art: art, sidebarSide: side, sidebarHidden: hidden)
                    defer { rig.tearDown() }
                    if art != nil { try #require(rig.root.backdrop.art != nil, "the window shows wallpaper art") }
                    let what = "\(art.map { "art \($0.rawValue)" } ?? "opaque"), sidebar \(hidden ? "hidden" : side.rawValue)"
                    for edge in rig.windowEdges {
                        let outlines = rig.outlines(at: edge)
                        #expect(outlines.count == 1, "\(what), window edge \(edge.rawValue): one outline, got \(outlines)")
                    }
                }
            }
        }
    }
}
