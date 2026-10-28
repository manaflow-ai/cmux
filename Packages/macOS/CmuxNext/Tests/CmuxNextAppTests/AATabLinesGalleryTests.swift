import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Stills of the listed tab rows' looks (`sidebar.tabLines`; Leo 2026-10-27: "look at what's redundant and
/// look at what's useful"), light and dark: a lane workspace listing "~" and "host/its own name" (Leo's
/// screenshot), and a workspace with two Claude chats, one working with status words, one waiting. Written
/// under `tab-lines-gallery/` in the package and bundled to `tab-lines-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized) struct AATabLinesGalleryTests {
    static let packageRoot = AANestedGroupsGalleryTests.packageRoot

    private static func tab(_ id: String, _ title: String, kind: SidebarTabKind = .terminal, brand: String? = nil,
                            agent: String? = nil, words: String? = nil, folder: String? = "~", state: StatusIndicatorState = .idle) -> SidebarTab {
        var tab = SidebarTab(id: TabID(id), title: title, kind: kind, brand: brand)
        (tab.agent, tab.words, tab.folder, tab.state) = (agent, words, folder, state)
        return tab
    }

    static func sections() -> [SidebarSection] {
        var lane = SidebarWorkspace(id: WorkspaceID("lane"), title: "rail-jump-final")
        lane.tabs = [tab("l1", "~"), tab("l2", "gcp-codex-lane-1/rail-jump-final")].map { var tab = $0; tab.workspaceName = lane.title; return tab }
        var chats = SidebarWorkspace(id: WorkspaceID("chats"), title: "sidebar polish", agentWorking: true, activity: .working)
        chats.tabs = [
            tab("c1", "Tuck the tab lines under the row", kind: .agentChat, brand: "claude", agent: "Claude Code",
                words: "Running fleet tests", state: .working),
            tab("c2", "Per-tab metadata", kind: .agentChat, brand: "claude", agent: "Claude Code", state: .waiting),
            tab("c3", "~/src/cmux", folder: "~/src/cmux"),
        ]
        chats.tabs = chats.tabs.map { var tab = $0; tab.workspaceName = chats.title; return tab }
        chats.focusedTab = TabID("c1")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(lane), .workspace(chats)])]
    }

    private static func draw(look: SidebarTabLineLook, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        TunableStore.shared.set(SidebarTunables.tabLines.key, look.tunableValue)
        SidebarTunablesWatch.shared.changed()
        let width: CGFloat = 280, height: CGFloat = 220
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        let model = SidebarModel(sections: sections(), activeWorkspaceID: WorkspaceID("chats"))
        model.showWorkspaceTabs = true
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer {
            TunableStore.shared.set(SidebarTunables.tabLines.key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        let out = Self.packageRoot.appending(path: "tab-lines-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, dark) in [("light", false), ("dark", true)] {
            for look in SidebarTabLineLook.allCases {
                let url = out.appending(path: "\(look.rawValue)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, try Self.draw(look: look, dark: dark), nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "tab-lines-gallery.tar", "tab-lines-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
