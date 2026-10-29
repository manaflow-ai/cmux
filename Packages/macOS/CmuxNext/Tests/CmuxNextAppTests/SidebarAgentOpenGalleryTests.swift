import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The sidebar rows of agent-opened workspaces, mapped from the daemon's tree as the app maps them, with
/// their tab rows shown (Leo 2026-10-28: "we don't want to just be seeing these bare terminals ... I'd rather
/// just see the other thing instead of that, you know, tilde."): one an older `cmux agent open` made (an idle
/// "~" shell focused beside the chat), one it makes now (the chat alone). Artifact
/// `sidebar-agent-open-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct SidebarAgentOpenGalleryTests {
    private static let host = "install:agent-open-gallery"

    private static func chat(_ surface: UInt64, session: String) -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        return tab
    }

    /// Workspace 1: the shell (focused last) beside the chat. Workspace 2: the chat alone.
    private static func rows() throws -> [SidebarWorkspace] {
        let shell = TabSnapshot(surface: 1, terminalID: "10", kind: .pty, title: "~", cwd: NSHomeDirectory())
        let older = ScreenSnapshot(id: 1, layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2)),
                                   panes: [PaneSnapshot(id: 1, focusedAt: 2, tabs: [shell]),
                                           PaneSnapshot(id: 2, focusedAt: 1, tabs: [chat(2, session: "s-lane")])])
        let now = ScreenSnapshot(id: 2, layout: .leaf(3), panes: [PaneSnapshot(id: 3, focusedAt: 1, tabs: [chat(3, session: "s-review")])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-11", screens: [older]),
                                                      WorkspaceSnapshot(id: 2, key: nil, name: "workspace-12", screens: [now])]))
        let titles = ["s-lane": "Fix the sidebar labels", "s-review": "Review the footer"]
        return store.workspaces.map { workspace in
            SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
                .init(title: tab.agentSession.map { titles[$0.session ?? ""] ?? "" } ?? tab.titleText)
            }, tabTitle: { tab in tab.agentSession.map { titles[$0.session ?? ""] ?? "" } ?? tab.titleText })
        }
    }

    static func render(dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = try Self.rows()
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })],
                                 activeWorkspaceID: rows[1].id)
        model.showWorkspaceTabs = true
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.renderNow()
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderAgentOpenedRows() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-agent-open-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            try AAGroupHeaderDensityGalleryTests.write(try Self.render(dark: dark), to: out.appending(path: dark ? "dark.png" : "light.png"))
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-agent-open-gallery.tar", "sidebar-agent-open-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
