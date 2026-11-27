import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The footer's Live button (RFD 0141 phase 1) rendered through the real sidebar: the default footer (the button is
/// on by default, with an explicit hidden variant through `sidebar.showLiveToggle`; Spaces off (one space) and on
/// (three), Live off and on, light and dark. Set CMUX_TEST_REQUIRE_GUI=1 to write PNGs to `sidebar-live-gallery/`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarLiveToggleGalleryTests {
    struct Variant: Sendable {
        let name: String
        let spaces: Bool
        let live: Bool
        /// An explicit value for `sidebar.showLiveToggle`; nil keeps the default (on).
        var showToggle: Bool?
    }

    static let variants = [
        Variant(name: "default-spaces-off", spaces: false, live: false),
        Variant(name: "default-spaces-on", spaces: true, live: false),
        Variant(name: "hidden-spaces-off", spaces: false, live: false, showToggle: false),
        Variant(name: "hidden-spaces-on", spaces: true, live: false, showToggle: false),
        Variant(name: "spaces-off-live-off", spaces: false, live: false, showToggle: true),
        Variant(name: "spaces-off-live-on", spaces: false, live: true, showToggle: true),
        Variant(name: "spaces-on-live-off", spaces: true, live: false, showToggle: true),
        Variant(name: "spaces-on-live-on", spaces: true, live: true, showToggle: true),
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
            ? [SidebarProfile(id: ProfileKey("a"), name: "Work", color: nil), SidebarProfile(id: ProfileKey("b"), name: "Home", color: nil),
               SidebarProfile(id: ProfileKey("c"), name: "Side", color: nil)]
            : [SidebarProfile(id: ProfileKey("a"), name: "Work", color: nil)]
        let design = DesignSettings()
        if let showToggle = variant.showToggle { design.sidebarSections.showLiveToggle = showToggle }
        let sidebar = SidebarView(model: model, design: design)
        sidebar.live = SidebarLiveState(isLive: variant.live, people: [])
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(sidebar.liveButton.isHidden == (variant.showToggle == false), "\(variant.name): the Live button hides only when turned off")
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
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-live-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            for variant in Self.variants {
                let image = try Self.render(variant, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(variant.name).png"))
            }
        }
    }
}
