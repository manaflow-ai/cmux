import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Crops for Lawrence 2026-11-07 ("i pinned a workspace and it's name disappeared and went back to workspace-936"):
/// three workspaces as their list rows draw them (the real list, `SidebarMapping.row` with the list's page face), and
/// below them the same three pinned, as band rows (`SidebarItemRowView` from `SidebarWorkspaceItems.workspaceInfo`):
/// a terminal nobody named, a page nobody named, and one the person renamed. Dark and light, written under
/// `pinned-title-gallery/` as `pinned-<dark|light>.png` and `pinned.png`, bundled to `pinned-title-gallery.tar` for
/// `cmux-ci run --artifact`, so a run before the fix and one after compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPinnedTitleGalleryTests {
    static let width: CGFloat = 240

    static func workspaces() throws -> [(WorkspaceModel, String)] {
        [(try PinnedWorkspaceKeepsTitleTests.workspace(name: "workspace-936"), "cmux"),
         (try PinnedWorkspaceKeepsTitleTests.workspace(name: "workspace-937", cwd: nil, url: "https://github.com/manaflow-ai/cmux/pull/37866"),
          "Sidebar face rules · PR #37866"),
         (try PinnedWorkspaceKeepsTitleTests.workspace(name: "workspace-938", title: "Release notes"), "cmux")]
    }

    static func crop(dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let workspaces = try workspaces()
        let rows = workspaces.map { SidebarMapping.shared.row($0.0, machine: .local, pageFace: PinnedWorkspaceKeepsTitleTests.face($0.1)) }
        let (list, window) = SidebarFaviconPlaceholderTests.list(rows)
        defer { window.close() }
        let root = try #require(window.contentView)
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        PointerHover.setDebugPointer(nil, in: window)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
        let first = try HomePinnedRowAlignmentTests.row(list, rows[0].id), last = try HomePinnedRowAlignmentTests.row(list, rows[rows.count - 1].id)
        let listArea = root.convert(first.bounds, from: first).union(root.convert(last.bounds, from: last))
        // The pinned band rows, under the list rows, at the list rows' height.
        let rowHeight = first.bounds.height
        var bandTop = listArea.minY - 12
        var bandArea = NSRect.null
        for (workspace, label) in workspaces {
            let info = SidebarWorkspaceItems.workspaceInfo(workspace, machine: .local, pageFace: PinnedWorkspaceKeepsTitleTests.face(label))
            let item = SidebarItemRowView(frame: NSRect(x: 0, y: bandTop - rowHeight, width: width, height: rowHeight))
            root.addSubview(item)
            item.configure(info, style: .list)
            bandArea = bandArea.union(item.frame)
            bandTop -= rowHeight
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        var area = listArea.union(bandArea).insetBy(dx: 0, dy: -4)
        area.origin.x = 0
        area.size.width = width
        return try AAPinnedNoCloseGalleryTests.crop(root, area)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "pinned-title-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var shots: [CGImage] = []
        for dark in [true, false] {
            let image = try Self.crop(dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "pinned-\(dark ? "dark" : "light").png"))
            shots.append(image)
        }
        try AAGroupHeaderDensityGalleryTests.write(try AAFaviconStyleGalleryTests.sheet([shots]), to: out.appending(path: "pinned.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "pinned-title-gallery.tar", "pinned-title-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
