import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Native footer captures for the always-available Spaces visibility control: light and dark themes,
/// the Spaces strip hidden and shown, and Live mode off and on. The button remains in the footer when
/// the strip is hidden, so its discoverability is visible in the rest state. Writes
/// `sidebar-spaces-toggle-gallery.tar` when `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarSpacesToggleGalleryTests {
    struct Variant: Sendable {
        let name: String
        let spaces: Bool
        let live: Bool
    }

    private static let variants = [
        Variant(name: "spaces-hidden-live-off", spaces: false, live: false),
        Variant(name: "spaces-hidden-live-on", spaces: false, live: true),
        Variant(name: "spaces-shown-live-off", spaces: true, live: false),
        Variant(name: "spaces-shown-live-on", spaces: true, live: true),
    ]

    private static func workspace(_ id: String, _ title: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: title, directory: "~/cmux", branch: "main",
                         rowKind: .terminal, kind: .terminal, activity: .idle)
    }

    private static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 360
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let sections = [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(workspace("ws-1", "Fix the build")), .workspace(workspace("ws-2", "Review PRs")),
        ])]
        let model = SidebarModel(sections: sections)
        model.profiles = variant.spaces
            ? [SidebarProfile(id: ProfileKey("work"), name: "Work", color: .blue),
               SidebarProfile(id: ProfileKey("home"), name: "Home", color: .green),
               SidebarProfile(id: ProfileKey("side"), name: "Side", color: .orange)]
            : [SidebarProfile(id: ProfileKey("work"), name: "Work", color: .blue)]
        model.activeProfileID = model.profiles[0].id
        let design = DesignSettings()
        design.sidebarSections.showLiveToggle = true
        design.sidebarSections.showSpaces = variant.spaces
        let sidebar = SidebarView(model: model, design: design)
        sidebar.spacesShown = variant.spaces
        sidebar.live = SidebarLiveState(isLive: variant.live, people: [])
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-spaces-toggle-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            for variant in Self.variants {
                let image = try Self.render(variant, dark: dark)
                let themeName = dark ? "dark" : "light"
                try AAGroupHeaderDensityGalleryTests.write(image,
                    to: out.appending(path: "\(themeName)-\(variant.name).png"))
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-spaces-toggle-gallery.tar", "sidebar-spaces-toggle-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
