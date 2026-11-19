import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The `sidebar.nestedSessions` gallery (Leo 2026-11-18: "for claude there's the font and the nested sessions and
/// whatever"): the real sidebar list drawn offscreen, light and dark (Soft Blue), with a workspace whose agent
/// started sub-sessions, folded (its chevron and rolled-up mark), open, and open two levels deep, plus `never`
/// (the list as before). Written as PNGs under `nested-sessions-gallery/` in the package and bundled to
/// `nested-sessions-gallery.tar` for `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AANestedSessionsGalleryTests {
    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let titles = ["Lawrence controller mini and Codex", "cmux classic memory expansion issue", "Data backup and storage options",
                      "Email filter misclassifying login emails"]
        return [SidebarSection(kind: .machine(machine), nodes: titles.enumerated().map {
            .workspace(SidebarWorkspace(id: WorkspaceID("w\($0.offset)"), title: $0.element))
        })]
    }

    static let sessions: [WorkspaceID: [SidebarSubSession]] = [WorkspaceID("w0"): [
        SidebarSubSession(id: "a1", title: "Review slots PR", kind: "general-purpose", state: .running),
        SidebarSubSession(id: "a2", parentID: "a1", title: "Check the motion tokens", state: .failed),
        SidebarSubSession(id: "a3", title: "Find the parser", kind: "Explore", state: .done),
    ]]

    static func render(theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 300, height: CGFloat = 320
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
        let list = SidebarListView(model: SidebarModel(sections: sections(), activeWorkspaceID: WorkspaceID("w0")))
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height // the root is not flipped: pin the list to the top
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "nested-sessions-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let nested = SidebarSessionTree.shared.nested
        let (mode, sessions) = (nested.mode, nested.sessions)
        defer {
            for row in nested.expanded { nested.fold(row, open: false) }
            for row in nested.collapsed { nested.fold(row, open: true) }
            (nested.mode, nested.sessions) = (mode, sessions)
        }
        let states: [(String, SidebarNestedSessionsMode, [String])] = [
            ("never", .never, []), ("folded", .collapsed, []), ("open", .collapsed, ["ws:w0"]),
            ("open-deep", .expanded, []),
        ]
        for (name, stateMode, opens) in states {
            nested.mode = stateMode
            nested.sessions = Self.sessions
            // Each state from the default folds: close what the last state opened, then open this one's rows.
            for row in nested.expanded { nested.fold(row, open: false) }
            for row in nested.collapsed { nested.fold(row, open: true) }
            for row in opens { nested.fold(row, open: true) }
            for (look, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                let image = try Self.render(theme: theme, dark: dark)
                let url = out.appending(path: "\(name)-\(look).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "nested-sessions-gallery.tar", "nested-sessions-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
