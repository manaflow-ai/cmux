import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of a chat's task list in the sidebar (David Beyer, Nov 20 call; `SidebarTaskProgressTests`), light and dark:
/// the real sidebar list with a working chat 3 of 7 through its list, one waiting on the person 1 of 4 through, and
/// a calm one with no list, before (no `taskProgress`) and after; and the working chat's hover card with its
/// progress, Now and Next. Written under `task-list-gallery/` in the package and bundled to `task-list-gallery.tar`
/// for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATaskListGalleryTests {
    static let packageRoot = AANestedGroupsGalleryTests.packageRoot

    static var working: SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("t1"), title: "Fix the passkey sign-in", lastActivity: Date(), agentWorking: true,
                                  kind: .harness, activity: .working, agentBrand: "claude")
        ws.taskProgress = SidebarTaskProgress(done: 3, total: 7, current: "Write the red test for the passkey prompt",
                                              next: "Fix the WebAuthn bridge")
        return ws
    }

    private static func sections(tasks: Bool) -> [SidebarSection] {
        var working = working
        var waiting = SidebarWorkspace(id: WorkspaceID("t2"), title: "Ship the Cloud billing page", lastActivity: Date(),
                                       kind: .harness, unread: .dot, activity: .waiting, agentBrand: "codex")
        if tasks {
            waiting.taskProgress = SidebarTaskProgress(done: 1, total: 4, current: "Wire the plan picker", next: "Stripe webhook")
        } else {
            working.taskProgress = nil
        }
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(working),
            .workspace(waiting),
            .workspace(SidebarWorkspace(id: WorkspaceID("t3"), title: "Release notes", lastActivity: Date(), kind: .harness,
                                        agentBrand: "claude")),
        ])]
    }

    private static func sidebar(tasks: Bool, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 140
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
        let list = SidebarListView(model: SidebarModel(sections: sections(tasks: tasks)))
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

    private static func hoverCard(dark: Bool) throws -> CGImage {
        try AAWorkspaceHoverCardVariantsGalleryTests.render(dark: dark) {
            let card = WorkspaceHoverCardView(style: .standard)
            card.configure(WorkspaceHoverCardContent.make(working, machine: nil, now: Date()), now: Date())
            return card
        }
    }

    private static func write(_ image: CGImage, _ url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = Self.packageRoot.appending(path: "task-list-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (mode, dark) in [("light", false), ("dark", true)] {
            for (name, tasks) in [("before", false), ("after", true)] {
                try Self.write(try Self.sidebar(tasks: tasks, dark: dark), out.appending(path: "sidebar-\(name)-\(mode).png"))
            }
            try Self.write(try Self.hoverCard(dark: dark), out.appending(path: "hover-card-\(mode).png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = Self.packageRoot
        tar.arguments = ["cf", "task-list-gallery.tar", "task-list-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
