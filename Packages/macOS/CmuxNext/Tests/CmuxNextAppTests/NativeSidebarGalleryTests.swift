import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// Native gallery captures for the sidebar states listed in issue #21964. The
/// JSON fixtures are shared with the web gallery entries; this suite is the
/// renderer that turns those entries into light/dark PNGs and a row-order
/// manifest for review.
@MainActor @Suite(.serialized, .closesItsWindows) struct NativeSidebarGalleryTests {
    struct Manifest: Codable {
        struct Entry: Codable {
            let fixture: String
            let scenario: SidebarGalleryFixture.Scenario
            let rowIDs: [String]
            let light: String
            let dark: String
        }
        let entries: [Entry]
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtureRoot = packageRoot.appending(path: "Fixtures/SidebarGallery")

    static func fixture(_ name: String) throws -> SidebarGalleryFixture {
        let url = fixtureRoot.appending(path: name + ".json")
        return try SidebarGalleryFixture(jsonData: Data(contentsOf: url))
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func render(_ fixture: SidebarGalleryFixture, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let snapshot = fixture.snapshot
        let width = CGFloat(snapshot.width), height: CGFloat = 680
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

        let shared = SidebarSessionTree.shared
        let oldState = shared.state
        let oldCollapsed = shared.collapsed
        shared.state = snapshot.tree
        for id in oldCollapsed.symmetricDifference(snapshot.tree.collapsed) { shared.toggle(id) }
        defer {
            for id in shared.collapsed.symmetricDifference(oldCollapsed) { shared.toggle(id) }
            shared.state = oldState
            window.close()
        }

        if fixture.scenario == .needsYou {
            let sidebar = SidebarView(model: SidebarModel(sections: snapshot.sections))
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: height)
            root.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.refreshNeedsYou()
            sidebar.layoutSubtreeIfNeeded()
        } else {
            let list = SidebarListView(model: SidebarModel(sections: snapshot.sections))
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
            root.addSubview(list)
            window.orderFrontRegardless()
            list.reload(animated: false)
        }
        root.layoutSubtreeIfNeeded()
        for view in Self.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = packageRoot.appending(path: "native-sidebar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let names = ["session-tree-deep", "sidebar-customization", "needs-you"]
        var entries: [Manifest.Entry] = []
        for name in names {
            let fixture = try Self.fixture(name)
            let light = name + "-light.png", dark = name + "-dark.png"
            try Self.write(try Self.render(fixture, theme: "Soft Blue Light", dark: false), to: out.appending(path: light))
            try Self.write(try Self.render(fixture, theme: "Soft Blue", dark: true), to: out.appending(path: dark))
            entries.append(.init(fixture: "Packages/macOS/CmuxNext/Tests/Fixtures/SidebarGallery/\(name).json",
                                 scenario: fixture.scenario, rowIDs: fixture.snapshot.rowIDs, light: light, dark: dark))
        }
        let manifest = try JSONEncoder().encode(Manifest(entries: entries))
        try manifest.write(to: out.appending(path: "manifest.json"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "native-sidebar-gallery.tar", "native-sidebar-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
