import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// `sidebar.folderlessUngrouped` rendered through the real sidebar (customize-app-profiles, the Claude Code app's
/// sidebar): no grouping, Group by Folder as it draws by default (a "No Folder" header over the rows with no folder),
/// Group by Folder with the option on (those rows last, no header), and the option on with every row folderless
/// (no header at all); light and dark. Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs to `sidebar-folderless-gallery/`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarFolderlessGalleryTests {
    struct Variant: Sendable {
        let name: String
        let groupBy: SidebarGroupBy
        let ungrouped: Bool
        var allFolderless = false
    }

    static let variants = [
        Variant(name: "group-none", groupBy: .none, ungrouped: false),
        Variant(name: "folder-default", groupBy: .folder, ungrouped: false),
        Variant(name: "folder-ungrouped", groupBy: .folder, ungrouped: true),
        Variant(name: "folder-ungrouped-all-folderless", groupBy: .folder, ungrouped: true, allFolderless: true),
    ]

    private static func workspace(_ id: String, _ title: String, folder: String?) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: title, directory: folder ?? "~", branch: "main",
                                   rowKind: .terminal, kind: .terminal, activity: .idle)
        row.folder = folder
        return row
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

        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let folder: (String) -> String? = { variant.allFolderless ? nil : $0 }
        let sections = [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(workspace("ws-1", "Fix the build", folder: folder("~/cmux"))),
            .workspace(workspace("ws-2", "Quick question", folder: nil)),
            .workspace(workspace("ws-3", "Review PRs", folder: folder("~/cmux"))),
            .workspace(workspace("ws-4", "Plan the week", folder: nil)),
        ])]
        let model = SidebarModel(sections: sections)
        let design = DesignSettings()
        design.sidebarSections.groupBy = variant.groupBy
        design.sidebarSections.folderlessUngrouped = variant.ungrouped
        model.applyListPreferences(design.sidebarSections)
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        let section = SectionID.machine(.local)
        let header = SidebarLayout.make(sections: sections, metrics: .standard, options: model.listOptions()).row(for: .folder(section, ""))
        #expect((header != nil) == (variant.groupBy == .folder && !variant.ungrouped), "\(variant.name): the No Folder header")
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
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-folderless-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            for variant in Self.variants {
                let image = try Self.render(variant, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(variant.name).png"))
            }
        }
    }
}
