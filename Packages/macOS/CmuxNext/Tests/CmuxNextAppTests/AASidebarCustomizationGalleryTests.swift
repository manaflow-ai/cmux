import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// CMUX-383's projection slices rendered through the real sidebar: the default,
/// a hidden and reordered section, a per-workspace group and order override, and
/// a hidden workspace, each at compact and comfortable density, light and dark.
/// Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarCustomizationGalleryTests {
    struct Variant: Sendable {
        let name: String
        let settings: SidebarProjectionCustomization
    }

    static let variants = [
        Variant(name: "default", settings: .defaults),
        Variant(name: "sections", settings: .init(hiddenSections: ["recents"], sectionOrder: ["projects"])),
        Variant(name: "workspace", settings: .init(workspaces: ["ws-2": .init(group: "grp", order: 0)])),
        Variant(name: "hidden-workspace", settings: .init(workspaces: ["ws-1": .init(hidden: true)])),
    ]

    static let densities: [SidebarDensity] = [.compact, .comfortable]

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
            SidebarSection(kind: .custom(.init(id: "recents", title: "Recents", showsTitle: true, region: .bottom)),
                           nodes: [.workspace(workspace("ws-3"))]),
        ]
    }

    private static func render(_ variant: Variant, dark: Bool, density: SidebarDensity = .compact) throws -> CGImage {
        _ = NSApplication.shared
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
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

        let model = SidebarModel(sections: sections())
        model.sectionCustomization = variant.settings
        model.setSections(sections())
        let sidebar = SidebarView(model: model, design: DesignSettings())
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

    @Test func aHiddenWorkspaceLeavesItsGroupAndComesBackOnShow() {
        let model = SidebarModel(sections: Self.sections())
        model.sectionCustomization = Self.variants[3].settings
        model.setSections(Self.sections())
        #expect(model.workspace(WorkspaceID("ws-1")) != nil)
        #expect(!model.sections.flatMap(\.nodes).contains { node in
            if case let .group(group) = node { return group.workspaces.contains { $0.id == WorkspaceID("ws-1") } }
            return false
        })
        model.sectionCustomization = .defaults
        #expect(model.sections.map(\.id) == Self.baseSectionIDs)
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
            for density in Self.densities {
                for variant in Self.variants {
                    let image = try Self.render(variant, dark: dark, density: density)
                    images.append(image)
                    let name = "\(dark ? "dark" : "light")-\(density.rawValue)-\(variant.name).png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                }
            }
        }
        let columns = Self.variants.count, rows = images.count / columns
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap,
                                         height: rows * h + (rows - 1) * gap, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            ctx.draw(image, in: CGRect(x: column * (w + gap), y: (rows - 1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
    }
}
