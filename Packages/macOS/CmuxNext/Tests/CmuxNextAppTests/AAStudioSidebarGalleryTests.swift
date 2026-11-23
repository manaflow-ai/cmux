import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextApps
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Studio's sidebar, drawn through the real sidebar (Leo 2026-11-18 on the Studio look: "there is nothing in the
/// sidebar, nothing at all"). `before-*` is Studio 1.0.1 as it was shown: its settings turned every row fact off
/// but the branch and Last Activity, which a chat row has none of, over a fresh demo profile (`before-fresh`) and
/// over real threads (`before-seeded`). `after-*` is the look's sidebar settings over the seeded demo state
/// (`SidebarNestedFixture` `.studio`): the Search row at the top (`sidebar.nav`), project groups (`sidebar.groupBy:
/// folder`), each thread's age at the right of its title (`sidebar.showTimestamps`), its status and pull request, a
/// neutral selected row (`appearance.selection`), in dark, light and ember. Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs
/// under `studio-sidebar-gallery/` with `all.png`, bundled to `studio-sidebar-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAStudioSidebarGalleryTests {
    init() { Motion.reduceMotionOverride = true }

    enum LookColors: String { case dark, light, ember }

    struct Variant {
        let name: String
        let after: Bool
        let seeded: Bool
        let palette: LookColors
    }

    static let variants = [
        Variant(name: "before-fresh", after: false, seeded: false, palette: .dark),
        Variant(name: "before-seeded", after: false, seeded: true, palette: .dark),
        Variant(name: "after-dark", after: true, seeded: true, palette: .dark),
        Variant(name: "after-light", after: true, seeded: true, palette: .light),
        Variant(name: "after-ember", after: true, seeded: true, palette: .ember),
    ]

    static let searchNav = [SidebarNavRow(action: "search.chats", title: "Search", symbol: "magnifyingglass")]
    static let home = LayoutItemID("item-home")
    static let store = LayoutItemID("item-store")

    /// The look's colors (examples/looks/studio's theme files): page, text, accent.
    static func input(_ palette: LookColors, neutral: Bool) -> ThemeInput {
        let (background, foreground, accent): (UInt32, UInt32, UInt32) = switch palette {
        case .dark: (0x0B0B0B, 0xF5F5F5, 0x346BF1)
        case .light: (0xFAFAFA, 0x18181B, 0x2563EB)
        case .ember: (0x1A1512, 0xF2E8DF, 0xD9773B)
        }
        var input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground),
                               palette: ThemeInput.ghosttyDefault.palette)
        input.accentColor = ThemeRGB(hex: accent)
        if neutral { input.selection = .neutral }
        return input
    }

    /// Studio 1.0.1's row facts (no icon, no folder; branch and Last Activity, which a chat row lacks), or the look's
    /// (no icon, the status and pull request lines, Last Activity off so the age sits at the right of the title).
    static func preferences(after: Bool) -> SidebarSectionsPreferences {
        var preferences = SidebarSectionsPreferences.defaults
        var shown = WorkspaceRowElements.standard.shown
        shown.remove(.icon)
        if after {
            shown.formUnion([.agentStatus, .pullRequest])
            preferences.density = .comfortable
            preferences.showTimestamps = true
            preferences.groupBy = .folder
        } else {
            shown.formUnion([.branch, .lastActivity])
            preferences.density = .compact
        }
        preferences.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: shown))
        return preferences
    }

    static func model(_ variant: Variant) -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                items: [LayoutItem(id: home, ref: SidebarLayoutDocument.homeRef), LayoutItem(id: store, ref: .app("cmux/app-store"))])
        let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
        let threads: [SidebarWorkspace]
        let selected: WorkspaceID
        if variant.seeded {
            threads = SidebarNestedFixture.studioThreads(now: Date())
            selected = SidebarNestedFixture.studioSelected
        } else {
            // A fresh demo profile: the one chat the recording opened.
            var chat = SidebarWorkspace(id: WorkspaceID("w-new"), title: "Summarize Folder Structure", directory: "~/Developer/todo-app",
                                        kind: .harness, folder: "~/Developer/todo-app")
            chat.chatActivity = Date()
            threads = [chat]
            selected = chat.id
        }
        let model = SidebarModel(sections: [block, CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: threads.map(SidebarNode.workspace))],
                                 activeWorkspaceID: selected)
        model.layout = SidebarLayoutDocument(sections: [top])
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        model.applyListPreferences(preferences(after: variant.after))
        model.transientTopItems = SidebarTransientItem.nav(variant.after ? searchNav : [])
        return model
    }

    static func sidebar(_ variant: Variant, in root: NSView) -> SidebarView {
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

    /// Runs `body` with the design's sidebar settings set as the variant's, then puts them back.
    static func withDesign<T>(_ variant: Variant, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.sidebarSections
        let preferences = preferences(after: variant.after)
        DesignSettings.shared.sidebarSections.density = preferences.density
        DesignSettings.shared.sidebarSections.showTimestamps = preferences.showTimestamps
        DesignSettings.shared.sidebarSections.groupBy = preferences.groupBy
        DesignSettings.shared.sidebarSections.workspaceRow = preferences.workspaceRow
        defer { DesignSettings.shared.sidebarSections = saved }
        return try body()
    }

    // MARK: Checks

    /// The seeded state is never empty or placeholder: three projects of named threads, each with an age.
    @Test func theSeededStateHasProjectsOfThreadsWithAges() {
        let threads = SidebarNestedFixture.studioThreads(now: Date())
        #expect(threads.count >= 6)
        #expect(Set(threads.compactMap(\.folder)).count == 3, "three projects")
        #expect(threads.allSatisfy { !$0.title.isEmpty && $0.rowAge != nil && $0.rowState == .live })
        #expect(threads.contains { if case .working = $0.activity { true } else { false } }, "one thread works")
        #expect(threads.contains { if case .waiting = $0.activity { true } else { false } }, "one waits on an approval")
        #expect(threads.contains { $0.pullRequest != nil }, "one has a pull request")
        #expect(threads.contains { $0.id == SidebarNestedFixture.studioSelected })
        #expect(SidebarNestedFixture(scenario: .studio).sections.flatMap(\.nodes).count == threads.count)
    }

    /// The look's sidebar draws a header per project with its threads under it, and the Search row above Home.
    @Test func theLookDrawsProjectHeadersThreadsAndTheSearchRow() {
        let variant = Self.variants[2]
        Self.withDesign(variant) {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
            let view = Self.sidebar(variant, in: root)
            let keys = view.list.displayed.rows.map(\.key)
            let folders = keys.filter { if case .folder = $0 { true } else { false } }
            let workspaces = keys.filter { if case .workspace = $0 { true } else { false } }
            #expect(folders.count == 3, "a header per project: \(keys)")
            #expect(workspaces.count == SidebarNestedFixture.studioThreads(now: Date()).count)
            let above = view.aboveRegion.content?.sections.flatMap(\.items).map(\.id) ?? []
            #expect(above.compactMap(SidebarTransientItem.navAction) == ["search.chats"])
        }
    }

    /// A rows view that names its rows by title (the documented example and the example looks) decorates them: the
    /// host read only `row`, so every title-named decoration was dropped.
    @Test func aRowNamedByTitleIsDecorated() throws {
        var scene = AppScene()
        scene.apply([
            .create(id: "root", type: "VStack", props: [:]),
            .create(id: "a", type: "Group", props: ["title": .string("Explain Todo App Structure"), "weight": .string("regular"),
                                                    "indicator": .string("dot")]),
            .create(id: "b", type: "Group", props: ["row": .string("w-due-dates"), "badge": .string("Working")]),
            .children(id: "root", children: ["a", "b"]),
            .root(id: "root"),
        ])
        let decorations = SidebarCustomizationService.decorations(scene)
        let byTitle = try #require(decorations["title:Explain Todo App Structure"])
        #expect(byTitle.weight == .regular && byTitle.indicator == .dot)
        #expect(decorations["w-due-dates"]?.badge == "Working")
        var row = SidebarWorkspace(id: WorkspaceID("w-x"), title: "Explain Todo App Structure", kind: .harness)
        row = row.decorated(by: decorations)
        #expect(row.activityStyle == .dot)
    }

    // MARK: Gallery

    static func render(_ variant: Variant) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 260, height: CGFloat = 560
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let dark = variant.palette != .light
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let name = "Studio \(variant.palette.rawValue)"
        let input = Self.input(variant.palette, neutral: variant.after)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        try Self.withDesign(variant) {
            _ = Self.sidebar(variant, in: root)
            root.layoutSubtreeIfNeeded()
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
        }
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        defer { Motion.reduceMotionOverride = nil }
        let store = ThemeScope.app.store
        let original = store.input
        defer { _ = store.apply(original) }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "studio-sidebar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for variant in Self.variants {
            let image = try Self.render(variant)
            images.append(image)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.name).png"))
        }
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: images.count * w + (images.count - 1) * gap, height: h, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in images.enumerated() {
            ctx.draw(image, in: CGRect(x: index * (w + gap), y: 0, width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "studio-sidebar-gallery.tar", "studio-sidebar-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
