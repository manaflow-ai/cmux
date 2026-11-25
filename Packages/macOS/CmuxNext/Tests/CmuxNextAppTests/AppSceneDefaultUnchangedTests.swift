import AppKit
@testable import CmuxNextApp
@testable import CmuxNextApps
import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The widget host (cmux#45106) changes the shared native scene renderer: a stack taller than its
/// content gives the slack to its spacers, a node's `transition` and a text's `contentTransition`
/// run, and a text label gets its own layer. Those are widget-tile behaviors
/// (``AppSceneHostingView/fillsBounds``): every other app scene (a sidebar section, a hover card, a
/// pane) draws as it did before widgets. And a sidebar with no widget app installed draws exactly
/// what it drew before, and its menus gain nothing.
@MainActor @Suite(.serialized, .closesItsWindows) struct AppSceneDefaultUnchangedTests {
    // MARK: Scenes

    /// A column 200 points tall (its frame), with a spacer between two lines: the kit's widget shape
    /// (a title, a Spacer, a big number), as a sidebar section could write it before widgets.
    private static func column(transition: Bool = false) -> AppSceneModel {
        let model = AppSceneModel()
        model.apply([
            .create(id: "col", type: "VStack", props: ["frame": ["height": 200]]),
            .create(id: "top", type: "Text", props: ["text": "Top", "contentTransition": "numericText"]),
            .create(id: "gap", type: "Spacer", props: [:]),
            .create(id: "bottom", type: "Text", props: transition ? ["text": "Bottom", "transition": "opacity"] : ["text": "Bottom"]),
            .children(id: "col", children: ["top", "gap", "bottom"]),
            .root(id: "col"),
        ])
        return model
    }

    /// The scene in a window (no screen needed: an exit with no screen ends at once), laid out.
    private static func host(_ model: AppSceneModel, fillsBounds: Bool) -> (AppSceneHostingView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.fillsBounds = fillsBounds
        hosting.frame = NSRect(x: 0, y: 0, width: 240, height: fillsBounds ? 200 : 300)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    private static func text(_ string: String, in hosting: NSView) -> AppSceneTextNSView? {
        all(hosting).compactMap { $0 as? AppSceneTextNSView }.first { $0.label.stringValue == string }
    }

    private static func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    // MARK: Spacers

    /// Before widgets a vertical stack laid its children from the top, whatever its frame: the line
    /// after the spacer sits right under the first. Red if the slack reaches a non-widget scene.
    @Test func aTallStackOutsideAWidgetKeepsItsSpacerEmpty() throws {
        #expect(AppSceneHostingView(model: AppSceneModel(), bundleDirectory: nil).fillsBounds == false, "a host fills its bounds only when it asks")
        let (hosting, window) = Self.host(Self.column(), fillsBounds: false)
        defer { Self.close(window) }
        let top = try #require(Self.text("Top", in: hosting))
        let bottom = try #require(Self.text("Bottom", in: hosting))
        let gap = try #require(Self.all(hosting).first { ($0 as? AppSceneNodeNSView)?.isSpacer == true })
        let column = try #require(bottom.superview)
        #expect(column.frame.height == 200, "the column takes its frame's height")
        #expect(gap.frame.height == 0, "the spacer takes nothing: \(gap.frame)")
        #expect(bottom.frame.minY == top.frame.maxY, "the line after the spacer sits under the first, as before widgets: \(bottom.frame.minY) vs \(top.frame.maxY)")
        #expect(column.frame.width <= 240 && column.frame.minY == 0)
    }

    /// In a widget tile the same scene fills the tile and the spacer pushes the last line down.
    @Test func inAWidgetTileTheSpacerTakesTheSlack() throws {
        let (hosting, window) = Self.host(Self.column(), fillsBounds: true)
        defer { Self.close(window) }
        let bottom = try #require(Self.text("Bottom", in: hosting))
        let column = try #require(bottom.superview)
        #expect(bottom.frame.maxY >= column.bounds.height - 1, "the last line sits at the bottom: \(bottom.frame) in \(column.bounds)")
    }

    // MARK: Transitions

    /// Before widgets a node left at once: its view is gone in the same layout. Red if `transition`
    /// runs outside a widget tile (the exit kept the view in its parent).
    @Test func aRemovedNodeWithATransitionLeavesAtOnceOutsideAWidget() throws {
        let model = Self.column(transition: true)
        let (hosting, window) = Self.host(model, fillsBounds: false)
        defer { Self.close(window) }
        let bottom = try #require(Self.text("Bottom", in: hosting))
        model.apply([.children(id: "col", children: ["top", "gap"]), .remove(id: "bottom")])
        hosting.layoutSubtreeIfNeeded()
        #expect(bottom.superview == nil, "the removed node's view left its parent")
        #expect(!bottom.isLeaving)
        #expect(bottom.alphaValue == 1)
    }

    /// In a widget tile the exit runs, and the view still goes when it ends: at once on a host whose
    /// test window has no screen, after the fade where it has one (a fleet host with a display gives
    /// the never-shown window a screen, so `Motion.canAnimate` lets the fade run there).
    @Test func inAWidgetTileARemovedNodeStillGoesWhenItsExitEndsAtOnce() async throws {
        let model = Self.column(transition: true)
        let (hosting, window) = Self.host(model, fillsBounds: true)
        defer { Self.close(window) }
        let bottom = try #require(Self.text("Bottom", in: hosting))
        model.apply([.children(id: "col", children: ["top", "gap"]), .remove(id: "bottom")])
        hosting.layoutSubtreeIfNeeded()
        if window.screen == nil {
            #expect(bottom.superview == nil, "an exit that ended at once removed the view")
            return
        }
        #expect(bottom.superview == nil || bottom.isLeaving, "the exit did not run")
        for _ in 0..<300 where bottom.superview != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(bottom.superview == nil, "the view stayed after its exit ended")
        #expect(!bottom.isLeaving)
    }

    /// Before widgets a text label had no layer of its own and a new value drew at once. Red if a
    /// label outside a widget tile gets its own layer.
    @Test func aTextOutsideAWidgetKeepsItsLabelWithoutItsOwnLayer() throws {
        let model = Self.column()
        let (hosting, window) = Self.host(model, fillsBounds: false)
        defer { Self.close(window) }
        let top = try #require(Self.text("Top", in: hosting))
        #expect(!top.label.wantsLayer)
        model.apply([.update(id: "top", props: ["text": "Top 2", "contentTransition": "numericText"])])
        hosting.layoutSubtreeIfNeeded()
        #expect(top.label.stringValue == "Top 2")
        #expect(!top.label.wantsLayer, "no layer of its own: the new value drew as before widgets")
        #expect(top.label.layer?.animationKeys()?.isEmpty ?? true, "no content transition ran")
    }

    // MARK: The sidebar with no widget app

    /// No app installed, no widget placed: what a person who never installs a widget app has.
    final class EmptyTransport: AppsTransport {
        var availability: AppsAvailability = .available(epoch: 1)
        var onEvent: ((AppsTransportEvent) -> Void)?
        var mounted: [String] = []
        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply { AppsListReply(revision: 1, apps: []) }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func storeCall(_ op: String, args: AppJSON, origin: AppOrigin) async throws(AppsTransportError) -> AppJSON {
            guard op == "apps.widgets.list" else { return .object([:]) }
            return ["widgets": [], "layout": ["revision": 1, "sidebar": []]]
        }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) { mounted.append(mountID) }
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON { .null }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    /// The sidebar's app sections as base drew them: the same provider, with no widget area (no
    /// `providedSections`, the protocol's default).
    final class BaseSections: SidebarAppSectionProvider {
        let provider: AppSectionProvider
        init(_ provider: AppSectionProvider) { self.provider = provider }
        var onContentChange: (() -> Void)? {
            get { provider.onContentChange }
            set { provider.onContentChange = newValue }
        }
        func title(for contribution: String) -> String? { provider.title(for: contribution) }
        func makeView(for contribution: String) -> NSView? { provider.makeView(for: contribution) }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { provider.preferredHeight(for: contribution, width: width) }
    }

    private static func settle(_ client: AppsClient) async {
        for _ in 0..<200 {
            await Task.yield()
            await client.tail?.value
        }
    }

    /// Every drawn view of `sidebar`, as its class, frame and whether it shows, in tree order.
    private static func drawn(_ sidebar: NSView) -> [String] {
        func walk(_ view: NSView, _ depth: Int) -> [String] {
            ["\(depth) \(type(of: view)) \(NSStringFromRect(view.frame)) hidden=\(view.isHidden)"] + view.subviews.flatMap { walk($0, depth + 1) }
        }
        return walk(sidebar, 0)
    }

    private static func sidebar(_ sections: SidebarAppSectionProvider) -> (SidebarView, NSWindow) {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let members = (1...3).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "w\($0)")) }
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: members)], activeWorkspaceID: nil)
        model.layout = SidebarLayoutDocument(sections: [
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        sidebar.appSections = sections
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.fitToClip()
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// With no widget app installed the sidebar draws exactly what base drew (every view, frame and
    /// visibility), shows no widget section, mounts nothing, and its menus gain no item. Red if the
    /// widget area draws, mounts or adds a menu item for a person with no widget app.
    @Test func withNoWidgetAppTheSidebarDrawsWhatBaseDrew() async throws {
        let transport = EmptyTransport()
        let client = AppsClient(transport: transport)
        client.start()
        let head = SidebarAppSections(client: client, isPresented: { _ in true })
        await Self.settle(client)
        let widgets = try #require(head.widgets, "the sidebar has its widget area")
        #expect(!widgets.isShown)
        #expect(head.providedSections.isEmpty, "no widget section in the band below the list")
        #expect(transport.mounted.isEmpty, "no widget mounts")

        let (headSidebar, headWindow) = Self.sidebar(head)
        defer { headWindow.close() }
        let (baseSidebar, baseWindow) = Self.sidebar(BaseSections(AppSectionProvider(client: client)))
        defer { baseWindow.close() }
        #expect(Self.drawn(headSidebar) == Self.drawn(baseSidebar), "the sidebar draws what base drew")
        #expect(headSidebar.belowRegion.subviews.count == baseSidebar.belowRegion.subviews.count)

        // The header's and the background's menus: Edit Widgets and Add Widget only with a widget to place.
        let menu = NSMenu()
        menu.addItem(withTitle: "New Workspace", action: nil, keyEquivalent: "")
        let titles = menu.items.map(\.title)
        let same = widgets.appendingMenuItems(to: menu)
        #expect(same === menu)
        #expect(menu.items.map(\.title) == titles, "the menu gains nothing")
        #expect(widgets.appendingMenuItems(to: nil) == nil, "no menu where base had none")
    }
}
