import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Nested sessions as Claude's desktop app draws them (Leo: "Claude Code (and the Claude desktop app's Code tab)
/// shows subagents and sub-sessions nested under the parent chat"), with `sidebar.sessionTree` on: the real
/// sidebar list drawn offscreen over the `sessionTree` capture fixture, in Clay Orange light and dark. Written
/// as PNGs under `claude-session-tree-gallery/` in the package, bundled to `claude-session-tree-gallery.tar`
/// for `cmux-ci run --display --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAClaudeSessionTreeGalleryTests {
    /// One still.
    enum Variant: String, CaseIterable {
        /// `sidebar.sessionTree` off (the default): today's flat list.
        case off
        /// On: the chat's sessions under it (working, waiting on you, finished unread); the session that
        /// started two of its own is folded by default, its count and state chips showing.
        case open
        /// That nested session opened too: every level drawn.
        case opened
        /// The chat folded: one row, its chevron, the count of every session under it and a chip per state.
        case folded
    }

    static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let fixture = SidebarNestedFixture(scenario: .sessionTree)
        let tree = SidebarSessionTree.shared
        let saved = tree.state
        let billing = WorkspaceID("w-billing"), rollout = WorkspaceID("w-rollout")
        tree.state = variant == .off ? nil : SidebarSessionTreeState(parents: fixture.parents)
        let toggled: WorkspaceID? = switch variant {
        case .opened where tree.isFolded(rollout): rollout
        case .folded where !tree.isFolded(billing): billing
        default: nil
        }
        if let toggled { tree.toggle(toggled) }
        defer {
            if let toggled { tree.toggle(toggled) }
            tree.state = saved
        }
        let theme = dark ? "Clay Orange" : "Clay Orange Light"
        let width = CGFloat(fixture.width), height: CGFloat = 420
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
        let list = SidebarListView(model: SidebarModel(sections: fixture.sections))
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        // The list sizes itself to its rows: pin it to the window's top (the root is not flipped).
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
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "claude-session-tree-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for variant in Variant.allCases {
            for (mode, dark) in [("light", false), ("dark", true)] {
                let url = out.appending(path: "\(variant.rawValue)-\(mode).png")
                try AAGroupHeaderDensityGalleryTests.write(try Self.render(variant, dark: dark), to: url)
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "claude-session-tree-gallery.tar", "claude-session-tree-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
