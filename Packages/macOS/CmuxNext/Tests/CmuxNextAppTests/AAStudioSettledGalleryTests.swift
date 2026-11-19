import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The Studio look's settled and archived chats, drawn through the real sidebar (Leo 2026-11-19: "the actual
/// functionality and features of them"). The threads are the Studio demo state's (lane/studio-sidebar's
/// `SidebarNestedFixture.studioThreads`, copied here until it lands) grouped by project folder (`sidebar.groupBy:
/// folder`), with one per state: the selected thread, one working, one waiting on an approval, an unread answer, a
/// failed turn, settled threads and archived ones. `off-dark` is the setting off (today's sidebar); `folded-*` has
/// `sidebar.settleFinished` on with each project's "Settled (N)" row closed, `open-*` with them open, `risen-dark`
/// after a settled thread got a new turn. Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs under `studio-settled-gallery/`
/// with `all.png`, bundled to `studio-settled-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAStudioSettledGalleryTests {
    init() { Motion.reduceMotionOverride = true }

    struct Variant {
        let name: String
        let settles: Bool
        let open: Bool
        let dark: Bool
        var risen = false
    }

    static let variants = [
        Variant(name: "off-dark", settles: false, open: false, dark: true),
        Variant(name: "folded-dark", settles: true, open: false, dark: true),
        Variant(name: "open-dark", settles: true, open: true, dark: true),
        Variant(name: "folded-light", settles: true, open: false, dark: false),
        Variant(name: "open-light", settles: true, open: true, dark: false),
        Variant(name: "risen-dark", settles: true, open: false, dark: true, risen: true),
    ]

    static let selected = WorkspaceID("w-explain-structure")
    static let projects = ["todo-app", "billing-api", "marketing-site"]

    /// The demo threads, newest first, each in its project folder.
    static func threads(now: Date, risen: Bool = false) -> [SidebarWorkspace] {
        func thread(_ id: String, _ title: String, _ project: String, minutesAgo: Double, activity: StatusIndicatorState = .idle,
                    chip: SidebarPriorityEntry.State? = nil, working: Bool = false, status: String? = nil,
                    pullRequest: String? = nil, unread: UnreadState = .none, archived: Bool = false) -> SidebarWorkspace {
            let folder = "~/Developer/\(project)"
            var ws = SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: folder, status: status, pullRequest: pullRequest,
                                      lastActivity: now.addingTimeInterval(-60 * minutesAgo), agentWorking: working, kind: .harness,
                                      unread: unread, activity: activity, folder: folder)
            ws.agentChip = chip
            ws.isArchived = archived
            return ws
        }
        let day = 24.0 * 60
        return [
            thread("explain-structure", "Explain Todo App Structure", "todo-app", minutesAgo: 0),
            thread("delete-endpoint", "Add Todo Delete Endpoint", "todo-app", minutesAgo: 1, activity: .waiting(kind: .permission),
                   chip: .needsYou, status: "Approval"),
            thread("due-dates", "Add Due Dates to Todos", "todo-app", minutesAgo: 5, activity: .working(progress: nil),
                   working: true, status: "Working"),
            thread("search", "Add Todo Search", "todo-app", minutesAgo: 90),
            thread("webhook-retries", "Retry Failed Payment Webhooks", "billing-api", minutesAgo: 48, chip: .done,
                   pullRequest: "#212", unread: .dot),
            thread("refunds", "Refund Partial Payments", "billing-api", minutesAgo: 70, activity: .error, chip: .failed),
            risen
                ? thread("invoice-pdf", "Fix Invoice PDF Totals", "billing-api", minutesAgo: 0, activity: .working(progress: nil),
                         working: true, status: "Working", pullRequest: "#209")
                : thread("invoice-pdf", "Fix Invoice PDF Totals", "billing-api", minutesAgo: 3 * 60, pullRequest: "#209"),
            thread("pricing-copy", "Tighten Pricing Page Copy", "marketing-site", minutesAgo: day),
            thread("og-images", "Generate Open Graph Images", "marketing-site", minutesAgo: 3 * day),
            thread("lighthouse", "Audit Lighthouse Scores", "marketing-site", minutesAgo: 12 * day, archived: true),
            thread("old-hero", "Rewrite the Hero Section", "marketing-site", minutesAgo: 20 * day, archived: true),
        ]
    }

    /// The look's sidebar settings: project folders, ages, status and pull request lines, no icon.
    static func preferences(settles: Bool) -> SidebarSectionsPreferences {
        var preferences = SidebarSectionsPreferences.defaults
        var shown = WorkspaceRowElements.standard.shown
        shown.remove(.icon)
        shown.formUnion([.agentStatus, .pullRequest])
        preferences.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: shown))
        preferences.showTimestamps = true
        preferences.groupBy = .folder
        preferences.settleFinished = settles
        return preferences
    }

    static func model(_ variant: Variant) -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let threads = threads(now: Date(), risen: variant.risen)
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: threads.map(SidebarNode.workspace))],
                                 activeWorkspaceID: selected)
        model.applyListPreferences(preferences(settles: variant.settles))
        if variant.open {
            model.openDoneFolds = Set(projects.map {
                SidebarDoneFoldID(section: .machine(.local), group: nil, kind: .settled, folder: "~/Developer/\($0)")
            })
        }
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
        let preferences = preferences(settles: variant.settles)
        DesignSettings.shared.sidebarSections.showTimestamps = preferences.showTimestamps
        DesignSettings.shared.sidebarSections.groupBy = preferences.groupBy
        DesignSettings.shared.sidebarSections.workspaceRow = preferences.workspaceRow
        DesignSettings.shared.sidebarSections.settleFinished = preferences.settleFinished
        defer { DesignSettings.shared.sidebarSections = saved }
        return try body()
    }

    static func keys(_ variant: Variant) -> [SidebarRowKey] {
        let model = model(variant)
        return SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions()).rows.map(\.key)
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID("w-\(id)")) }
    static func settled(_ project: String) -> SidebarRowKey {
        .doneFold(SidebarDoneFoldID(section: .machine(.local), group: nil, kind: .settled, folder: "~/Developer/\(project)"))
    }

    // MARK: Checks

    /// Off draws every thread in its project in model order, with no Settled row: today's sidebar.
    @Test func offDrawsEveryThreadInPlace() {
        let keys = Self.keys(Self.variants[0])
        #expect(!keys.contains { if case let .doneFold(id) = $0 { id.kind == .settled } else { false } })
        #expect(keys.contains(Self.w("search")) && keys.contains(Self.w("pricing-copy")))
    }

    /// On, each project's seen, finished threads fold at the end of its rows; the selected, working, waiting, unread
    /// and failed threads stay where they are; archived threads stay in the Archive.
    @Test func eachProjectFoldsItsSettledThreadsAtItsEnd() throws {
        let keys = Self.keys(Self.variants[1])
        let todo = try #require(keys.firstIndex(of: Self.settled("todo-app")))
        let billing = try #require(keys.firstIndex(of: Self.settled("billing-api")))
        let marketing = try #require(keys.firstIndex(of: Self.settled("marketing-site")))
        for id in ["explain-structure", "delete-endpoint", "due-dates"] {
            #expect((keys.firstIndex(of: Self.w(id)) ?? .max) < todo, "\(id) stays above todo-app's Settled row")
        }
        for id in ["webhook-retries", "refunds"] {
            #expect((keys.firstIndex(of: Self.w(id)) ?? .max) < billing, "\(id) stays above billing-api's Settled row")
        }
        #expect(todo < billing && billing < marketing)
        for id in ["search", "invoice-pdf", "pricing-copy", "og-images", "lighthouse", "old-hero"] {
            #expect(!keys.contains(Self.w(id)), "\(id) is folded (settled or archived)")
        }
        #expect(keys.contains(.doneFold(.archive)), "archived threads keep the Archive row")
    }

    @Test func anOpenSettledRowListsItsThreadsUnderIt() throws {
        let keys = Self.keys(Self.variants[2])
        let marketing = try #require(keys.firstIndex(of: Self.settled("marketing-site")))
        #expect(Array(keys[(marketing + 1)...].prefix(2)) == [Self.w("pricing-copy"), Self.w("og-images")])
    }

    @Test func aNewTurnBringsASettledThreadBack() throws {
        let keys = Self.keys(Self.variants[5])
        let billing = try #require(keys.firstIndex(of: Self.settled("billing-api")) ?? keys.firstIndex(of: .folder(.machine(.local), "~/Developer/marketing-site")))
        let invoice = try #require(keys.firstIndex(of: Self.w("invoice-pdf")))
        #expect(invoice < billing)
    }

    // MARK: Gallery

    static func render(_ variant: Variant) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 260, height: CGFloat = 640
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        // The Studio look's colors (examples/looks/studio): page, text, accent.
        let (background, foreground, accent): (UInt32, UInt32, UInt32) = variant.dark ? (0x0B0B0B, 0xF5F5F5, 0x346BF1) : (0xFAFAFA, 0x18181B, 0x2563EB)
        var input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground), palette: ThemeInput.ghosttyDefault.palette)
        input.accentColor = ThemeRGB(hex: accent)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Studio \(variant.dark ? "dark" : "light")"), input: input, animated: false)
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
        let out = root.appending(path: "studio-settled-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for variant in Self.variants {
            let image = try Self.render(variant)
            images.append(image)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.name).png"))
        }
        let w = images[0].width, h = images[0].height, gap = 16
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: images.count * w + (images.count - 1) * gap, height: h, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in images.enumerated() {
            ctx.draw(image, in: CGRect(x: index * (w + gap), y: 0, width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "studio-settled-gallery.tar", "studio-settled-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
