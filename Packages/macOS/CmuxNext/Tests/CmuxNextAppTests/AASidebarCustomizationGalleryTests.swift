import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// CMUX-383's first two projection slices rendered through the real sidebar.
/// The variants exercise the default, a hidden section, section order,
/// workspace grouping and a hidden workspace: one per landed slice-2 setting.
/// `threads` is the chats-under-projects look (`sidebar.groupBy` folder,
/// `sidebar.showTimestamps` with `sidebar.relativeTimestamps`, `sidebar.workspaceRow.branch`).
/// Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarCustomizationGalleryTests {
    struct Variant: Sendable {
        let name: String
        let settings: SidebarProjectionCustomization
        /// Chats under their project folders, each with its age and its branch (`SidebarThreadsLookTests`).
        var threads = false
    }

    static let variants = [
        Variant(name: "default", settings: .defaults),
        Variant(name: "sections", settings: .init(hiddenSections: ["recents"], sectionOrder: ["projects"])),
        Variant(name: "workspace", settings: .init(workspaces: ["ws-2": .init(group: "grp", order: 0)])),
        Variant(name: "threads", settings: .defaults, threads: true),
        // "projects" is the machine section's alias and already leads, so order shows only by moving Recents up.
        // The planner reorders within a region (the app and fixed bands stay put), so Recents sits in the machine
        // section's middle region here.
        Variant(name: "order", settings: .init(sectionOrder: ["recents"])),
        Variant(name: "hidden-workspace", settings: .init(workspaces: ["ws-2": .init(hidden: true)])),
    ]

    private static func workspace(_ id: String, _ title: String? = nil) -> SidebarWorkspace {
        let title = title ?? "Workspace \(id)"
        return SidebarWorkspace(id: WorkspaceID(id), title: title, directory: "~/cmux", branch: "main",
                         rowKind: .terminal, kind: .terminal, activity: .idle)
    }

    private static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let group = SidebarGroup(id: GroupID("grp"), name: "Pinned work", workspaces: [workspace("ws-1")])
        return [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace("ws-2")), .group(group)]),
            SidebarSection(kind: .custom(.init(id: "recents", title: "Recents", showsTitle: true, region: .middle)),
                           nodes: [.workspace(workspace("ws-3"))]),
        ]
    }

    private static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 360
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

        let rows = variant.threads ? SidebarThreadsLookTests.sections(now: Date()) : Self.sections()
        let model = SidebarModel(sections: rows)
        model.sectionCustomization = variant.settings
        model.setSections(rows)
        // The sidebar applies its design's `sidebar.*` preferences to the model: the look goes there.
        let design = DesignSettings()
        if variant.threads { SidebarThreadsLookTests.applyLook(&design.sidebarSections) }
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
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

    @Test func projectionVariantsKeepTheDocumentRowsDeterministic() {
        let base = Self.sections()
        let model = SidebarModel(sections: base)
        model.sectionCustomization = Self.variants[1].settings
        model.setSections(base)
        #expect(model.sections.map(\.id) == [SectionID.machine(.local)])
        model.sectionCustomization = Self.variants[0].settings
        #expect(model.sections.map(\.id) == base.map(\.id))
    }

    @Test func selectingAHiddenWorkspaceKeepsItsSectionVisible() {
        let model = SidebarModel(sections: Self.sections())
        model.sectionCustomization = Self.variants[1].settings
        model.setSections(Self.sections())
        #expect(model.sections.map(\.id) == [SectionID.machine(.local)])
        model.activeWorkspaceID = WorkspaceID("ws-3")
        #expect(model.sections.map(\.id) == Self.baseSectionIDs)
    }

    private static var baseSectionIDs: [SectionID] { Self.sections().map(\.id) }

    @Test func orderAndHiddenWorkspaceVariantsChangeWhatTheGalleryDraws() throws {
        let order = try #require(Self.variants.first { $0.name == "order" })
        let model = SidebarModel(sections: Self.sections())
        model.sectionCustomization = order.settings
        model.setSections(Self.sections())
        #expect(model.sections.map(\.id) == Array(Self.baseSectionIDs.reversed()))

        let hidden = try #require(Self.variants.first { $0.name == "hidden-workspace" })
        model.sectionCustomization = hidden.settings
        model.setSections(Self.sections())
        #expect(model.sections.map(\.id) == Self.baseSectionIDs)
        let machineNodes = try #require(model.sections.first).nodes
        #expect(!machineNodes.contains { if case let .workspace(w) = $0 { w.id == WorkspaceID("ws-2") } else { false } })
    }

    @Test func selectionPreservesPatchedRowsWithoutRebuildingDefaultProjection() {
        let model = SidebarModel(sections: Self.sections())
        let updated = Self.workspace("ws-2", "Updated title")
        #expect(model.patchWorkspaces([updated]))
        _ = SidebarPerfCounters.report(reset: true)
        model.activeWorkspaceID = WorkspaceID("ws-1")
        #expect(model.workspace(WorkspaceID("ws-2"))?.title == "Updated title")
        #expect(SidebarPerfCounters.report(reset: true)["section_sets", default: 0] == 0)
    }

    @Test func reloadRestoresTheLatestContentOfVisibleAndHiddenRows() {
        let model = SidebarModel(sections: Self.sections())
        model.sectionCustomization = Self.variants[1].settings
        #expect(model.patchWorkspaces([Self.workspace("ws-2", "Visible update"),
                                      Self.workspace("ws-3", "Hidden update")]))
        model.sectionCustomization = .defaults
        #expect(model.workspace(WorkspaceID("ws-2"))?.title == "Visible update")
        #expect(model.workspace(WorkspaceID("ws-3"))?.title == "Hidden update")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-customization-gallery")
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
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap,
                                         height: 2 * h + gap, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
