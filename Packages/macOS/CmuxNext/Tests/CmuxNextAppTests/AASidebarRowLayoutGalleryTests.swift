import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Sidebar customization (CMUX-383, Leo: "Sidebar customization (look at BB and Herder)"): three
/// row layouts a person can write in `sidebar.workspaceRow.lines` (cmux-layout-reducer
/// `sidebar_row_layout`), drawn with the row elements the sidebar has today so the sheet shows the
/// same pixels the layouts resolve to. Columns: **quiet** (no layout written, today's default
/// row), **herd** (`[["icon", "name", "working"], ["process", "branch"]]`: what runs and on which
/// branch under the name, an agent-multiplexer list) and **threads** (`[["name"], ["directory",
/// "lastActivity"]]`: a thread list with its project folder and age). Dark on top, light below.
/// Written under `sidebar-row-layout-gallery/` with `all.png`, bundled to
/// `sidebar-row-layout-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarRowLayoutGalleryTests {
    /// A variant: its name and the row elements its layout resolves to.
    struct Variant {
        let name: String
        let row: WorkspaceRowPreferences
    }

    static let variants: [Variant] = [
        Variant(name: "quiet", row: .defaults),
        Variant(name: "herd", row: WorkspaceRowPreferences(base: WorkspaceRowElements(
            shown: [.icon, .working, .progress, .process, .branch], secondLineOrder: [.process, .branch]))),
        Variant(name: "threads", row: WorkspaceRowPreferences(base: WorkspaceRowElements(
            shown: [.directory, .lastActivity], secondLineOrder: [.directory, .lastActivity]))),
    ]

    static func sections(now: Date) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, dir: String, branch: String, process: String, minutes: Double,
                working: Bool = false, unread: UnreadState = .none) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: dir, branch: branch, process: process,
                             lastActivity: now.addingTimeInterval(-minutes * 60), rowKind: .agent, agentWorking: working,
                             kind: .terminal, unread: unread, activity: working ? .busy(progress: nil) : .idle)
        }
        let app = SidebarGroup(id: GroupID("g-app"), name: "cmux", color: .blue, workspaces: [
            ws("rows", "Sidebar row layouts", dir: "~/cmux", branch: "lane/sidebar-rows", process: "claude", minutes: 2, working: true),
            ws("caps", "Show more by 20", dir: "~/cmux", branch: "lane/caps", process: "codex", minutes: 40, unread: .dot),
            ws("perf", "Flick past a busy main thread", dir: "~/cmux", branch: "perf/flick", process: "claude", minutes: 180),
        ])
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("hq", "Weekly notes", dir: "~/hq", branch: "main", process: "zsh", minutes: 5)),
            .group(app),
            .workspace(ws("site", "Docs site", dir: "~/site", branch: "main", process: "codex", minutes: 60 * 26)),
        ])]
    }

    static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
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
        let design = DesignSettings()
        design.sidebarSections.workspaceRow = variant.row
        let sidebar = SidebarView(model: SidebarModel(sections: sections(now: Date())), design: design)
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

    /// The herd and threads layouts draw a second line on every row with facts, quiet on none.
    @Test func theVariantsDrawTheLinesTheirLayoutsName() throws {
        for variant in Self.variants {
            let design = DesignSettings()
            design.sidebarSections.workspaceRow = variant.row
            let sidebar = SidebarView(model: SidebarModel(sections: Self.sections(now: Date())), design: design)
            sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("w-hq"))] as? WorkspaceRowView)
            row.layoutSubtreeIfNeeded()
            #expect(row.subtitle.isHidden == (variant.name == "quiet"), "\(variant.name)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-row-layout-gallery")
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
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-row-layout-gallery.tar", "sidebar-row-layout-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
