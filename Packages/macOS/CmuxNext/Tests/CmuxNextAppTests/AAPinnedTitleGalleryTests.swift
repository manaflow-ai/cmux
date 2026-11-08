import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Crops for Lawrence 2026-11-07 ("i pinned a workspace and it's name disappeared and went back to workspace-936"):
/// three pinned workspaces as band rows (`SidebarItemRowView` from `SidebarWorkspaceItems.workspaceInfo`, given the list
/// rows' page face): a terminal nobody named (its list row reads "cmux"), a page nobody named (its list row reads the
/// page's title), and one the person renamed ("Release notes"). Dark and light, written under
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
        let rowHeight: CGFloat = 30, inset: CGFloat = 6
        let height = rowHeight * CGFloat(workspaces.count) + inset * 2
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = root
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        root.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        for (index, (workspace, label)) in workspaces.enumerated() {
            let info = SidebarWorkspaceItems.workspaceInfo(workspace, machine: .local, pageFace: PinnedWorkspaceKeepsTitleTests.face(label))
            let item = SidebarItemRowView(frame: NSRect(x: 0, y: height - inset - rowHeight * CGFloat(index + 1), width: width, height: rowHeight))
            root.addSubview(item)
            item.configure(info, style: .list)
        }
        PointerHover.setDebugPointer(nil, in: window)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return try AAPinnedNoCloseGalleryTests.crop(root, root.bounds)
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
