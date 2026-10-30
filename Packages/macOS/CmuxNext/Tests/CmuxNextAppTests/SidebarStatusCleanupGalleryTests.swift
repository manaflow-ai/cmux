import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Before/after stills for the Chrome-style sidebar cleanup: task-status lane
/// glyphs were leading every row; the row's trailing status dots already carry
/// the attention state, so the leading slot is empty.
@MainActor @Suite(.serialized) struct SidebarStatusCleanupGalleryTests {
    static func sections(leadingStatusIcons: Bool) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func workspace(_ id: String, _ title: String, status: SidebarTaskStatus, activity: StatusIndicatorState = .idle) -> SidebarWorkspace {
            var row = SidebarWorkspace(id: WorkspaceID("status-\(id)"), title: title, activity: activity)
            row.taskStatus = status
            if leadingStatusIcons { row.icon = status.glyph }
            return row
        }
        let sessions = SidebarGroup(id: GroupID("agent-sessions"), name: "Agent sessions", color: .pink,
                                    workspaces: [
                                        workspace("codex-19", "codex-19", status: .todo),
                                        workspace("review", "cp-codex-review", status: .needsAttention, activity: .waiting),
                                        workspace("composer", "composer-look", status: .todo),
                                        workspace("main", "main-pane-mode", status: .todo),
                                        workspace("webview", "webview-engine-spike", status: .todo),
                                    ])
        let coordinator = SidebarGroup(id: GroupID("coordinator"), name: "Coordinator", color: .grey,
                                       workspaces: [workspace("claude", "claude-sr2", status: .todo)])
        return [SidebarSection(kind: .machine(machine), nodes: [.group(sessions), .group(coordinator)])]
    }

    static func render(leadingStatusIcons: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 320, height: CGFloat = 300
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let input = try AANestedGroupsGalleryTests.input("Soft Blue")
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
        let sidebar = SidebarView(model: SidebarModel(sections: sections(leadingStatusIcons: leadingStatusIcons)), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = sidebar
        scope.root(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(sidebar) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderBeforeAfterGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-status-cleanup-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let before = try Self.render(leadingStatusIcons: true), after = try Self.render(leadingStatusIcons: false)
        try AAGroupHeaderDensityGalleryTests.write(before, to: out.appending(path: "before.png"))
        try AAGroupHeaderDensityGalleryTests.write(after, to: out.appending(path: "after.png"))
        let gap = 16, width = before.width + after.width + gap, height = max(before.height, after.height)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(before, in: CGRect(x: 0, y: 0, width: before.width, height: before.height))
        ctx.draw(after, in: CGRect(x: before.width + gap, y: 0, width: after.width, height: after.height))
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-status-cleanup-gallery.tar", "sidebar-status-cleanup-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
