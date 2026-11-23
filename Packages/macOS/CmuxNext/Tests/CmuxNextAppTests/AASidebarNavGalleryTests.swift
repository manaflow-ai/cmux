import AppKit
import CmuxNextActions
@testable import CmuxNextAgentLanes
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// `sidebar.nav`: a look's nav block of cmux actions at the top of the sidebar, drawn through the real
/// sidebar beside Projects and Recents (`sidebar.groupBy: recents`), as the Codex app's sidebar. Off
/// (no rows) draws today's sidebar. Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarNavGalleryTests {
    init() { Motion.reduceMotionOverride = true }

    struct Variant {
        let name: String
        let nav: [SidebarNavRow]
        let groupBy: SidebarGroupBy
    }

    static let codexNav = [
        SidebarNavRow(action: "palette.newAgentChat", title: "New chat", symbol: "square.and.pencil"),
        SidebarNavRow(action: "search.chats", title: "Search", symbol: "magnifyingglass"),
        SidebarNavRow(action: "palette.openWorkspacePullRequests", title: "Pull requests", symbol: "arrow.triangle.pull"),
        SidebarNavRow(action: "automations.show", title: "Scheduled", symbol: "clock"),
        SidebarNavRow(action: "appStore.show", title: "Plugins", symbol: "puzzlepiece.extension"),
    ]

    static let variants = [
        Variant(name: "off", nav: [], groupBy: .none),
        Variant(name: "codex", nav: codexNav, groupBy: .recents),
        Variant(name: "catalog-titles", nav: [SidebarNavRow(action: "palette.newAgentChat"), SidebarNavRow(action: "search.chats"),
                                              SidebarNavRow(action: "automations.show")], groupBy: .none),
    ]

    static let home = LayoutItemID("item-home")
    static let store = LayoutItemID("item-store")

    private static func workspace(_ id: String, _ title: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: title, directory: "~/code", branch: "main", rowKind: .agent, kind: .harness, activity: .idle)
    }

    private static func model(_ variant: Variant) -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                items: [LayoutItem(id: home, ref: SidebarLayoutDocument.homeRef), LayoutItem(id: store, ref: .app("cmux/app-store"))])
        let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
        let nodes: [SidebarNode] = [
            .group(SidebarGroup(id: GroupID("grp-a"), name: "clicksiq", workspaces: [workspace("ws-1", "Enable worktrees")])),
            .group(SidebarGroup(id: GroupID("grp-b"), name: "alldevneeds", workspaces: [workspace("ws-2", "Change background color"),
                                                                                       workspace("ws-3", "Rename UUID creator tool")])),
            .workspace(workspace("ws-4", "Update main page colors")),
            .workspace(workspace("ws-5", "Change UI")),
        ]
        let model = SidebarModel(sections: [block, CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: WorkspaceID("ws-2"))
        model.layout = SidebarLayoutDocument(sections: [top])
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        var preferences = SidebarSectionsPreferences.defaults
        preferences.groupBy = variant.groupBy
        model.applyListPreferences(preferences)
        model.transientTopItems = SidebarTransientItem.nav(variant.nav)
        return model
    }

    private static func sidebar(_ variant: Variant, in root: NSView) -> SidebarView {
        let sidebar = SidebarView(model: model(variant), design: DesignSettings.shared)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        sidebar.renderNow()
        sidebar.updateBands()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.fitToClip()
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func offDrawsNoNavBlock() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 480))
        let view = Self.sidebar(Self.variants[0], in: root)
        let above = view.aboveRegion.content?.sections.flatMap(\.items).map(\.id) ?? []
        #expect(!above.contains { SidebarTransientItem.navAction($0) != nil })
    }

    @Test func theNavBlockDrawsAboveHomeInItsOrderAndRunsItsActions() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 480))
        let view = Self.sidebar(Self.variants[1], in: root)
        let above = view.aboveRegion.content?.sections.flatMap(\.items).map(\.id) ?? []
        #expect(above.compactMap(SidebarTransientItem.navAction) == Self.codexNav.map(\.action))
        let block = view.list.blocks?.sections.values.flatMap(\.items).map(\.id) ?? []
        #expect(block.contains(Self.home), "Home stays in the list's top block, under the nav block")
        let infos = SidebarTransientItem.nav(Self.codexNav).map(\.info)
        #expect(infos.map(\.title) == ["New chat", "Search", "Pull requests", "Scheduled", "Plugins"])
    }

    @Test func aRowWithNoOverrideTakesTheActionsOwnTitleAndSymbol() throws {
        let item = try #require(SidebarTransientItem.nav([SidebarNavRow(action: "search.chats")]).first)
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == "search.chats" })
        #expect(item.info.title == descriptor.title)
        #expect(item.info.symbol == (descriptor.symbol.isEmpty ? "circle" : descriptor.symbol))
        #expect(SidebarTransientItem.navAction(item.item.id) == "search.chats")
        #expect(SidebarTransientItem.navAction(SidebarTransientItem.channelsID) == nil)
    }

    private static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 480
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        _ = Self.sidebar(variant, in: root)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-nav-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for variant in Self.variants {
                let image = try Self.render(variant, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(variant.name).png"))
            }
        }
        let columns = Self.variants.count
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: 2 * h + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            ctx.draw(image, in: CGRect(x: column * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
    }
}
