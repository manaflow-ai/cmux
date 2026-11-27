import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills for Lawrence 2026-11-03 ("make sure size of the pinned summary thing reflect size of ui compactness i
/// chose"): per `sidebar.density`, dark and light, one sheet with the text sizes side by side (default, large,
/// larger). Each cell is the real list with a Pinned block (one pinned workspace with a favicon) over a workspace
/// row, and the hover card that pinned row opens beside it. Written under `pinned-density-gallery/` as
/// `<density>-<dark|light>.png`, bundled to `pinned-density-gallery.tar` for `cmux-ci run --artifact`, so a run
/// before the fix and one after it compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPinnedDensityGalleryTests {
    static let cellSize = NSSize(width: 640, height: 400)

    static func cell(_ setting: PinnedSummaryDensityTests.Setting, dark: Bool) throws -> CGImage {
        try PinnedSummaryDensityTests.at(setting) {
            _ = NSApplication.shared
            Motion.reduceMotionOverride = true
            defer { Motion.reduceMotionOverride = nil }
            let size = Self.cellSize
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = root
            try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)

            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let pinnedID = WorkspaceID("ws-gallery-pinned")
            let pinnedSection = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarDocStore.pinnedSection)), nodes: [])
            let listed = SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: WorkspaceID("ws-gallery-a"), title: "api server", icon: .favicon(PinnedSummaryDensityTests.favicon))),
                .workspace(SidebarWorkspace(id: WorkspaceID("ws-gallery-b"), title: "Work on cmux")),
            ])
            let model = SidebarModel(sections: [pinnedSection, listed], activeWorkspaceID: nil)
            model.expanded = setting.density == .expanded
            let list = SidebarListView(model: model)
            var workspace = PinnedSummaryDensityTests.pinned
            workspace.title = "Cloud Chief rebuild"
            let item = LayoutItem(id: LayoutItemID("itm_gallery_pin"), ref: .workspace("local:ws-gallery-pinned"))
            var info = SidebarItemInfo(title: workspace.title, symbol: "globe")
            info.favicon = PinnedSummaryDensityTests.favicon
            info.leadingPin = true
            info.workspace = pinnedID
            info.workspaceRow = workspace
            let section = SidebarLayoutDocument.pinnedSection(items: [item])
            list.blocks = SidebarListBlocks(sections: [section.id.rawValue: section], infos: [item.id: info], collapsed: [],
                                            look: .quiet, metrics: .standard, drawsLines: false, appHeights: [:])
            list.frame = NSRect(x: 0, y: 0, width: 260, height: size.height)
            root.addSubview(list)
            window.orderFrontRegardless()
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()

            let card = WorkspaceHoverCardView()
            card.configure(.make(workspace, machine: nil, now: Date()))
            card.configureTabs(title: pinnedID.rawValue, tabs: workspace.tabs, machine: nil)
            let fitting = card.fittingSize
            card.frame = NSRect(x: 272, y: size.height - fitting.height - 8, width: fitting.width, height: fitting.height)
            root.addSubview(card)
            card.layoutSubtreeIfNeeded()
            return try AAPinnedNoCloseGalleryTests.crop(root, root.bounds)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "pinned-density-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for density in SidebarDensity.allCases {
            for dark in [true, false] {
                let cells = try SidebarTextSize.allCases.map {
                    try Self.cell(PinnedSummaryDensityTests.Setting(density: density, textSize: $0), dark: dark)
                }
                let gap = 12, w = cells.map(\.width).max() ?? 1, h = cells.map(\.height).max() ?? 1
                let ctx = try #require(CGContext(data: nil, width: cells.count * w + (cells.count + 1) * gap, height: h + 2 * gap,
                                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                for (index, image) in cells.enumerated() {
                    ctx.draw(image, in: CGRect(x: gap + index * (w + gap), y: gap + h - image.height, width: image.width, height: image.height))
                }
                try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()),
                                                           to: out.appending(path: "\(density.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "pinned-density-gallery.tar", "pinned-density-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
