import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the real sidebar list at every `sidebar.density`, Minimal Mode off and on (Lawrence
/// 2026-10-22: a group header is exactly as tall as a workspace row at every density). One open,
/// one collapsed and loading, one pinned and one nested group beside loose rows, in Soft Blue dark;
/// written under `group-header-gallery/` with `all.png` side by side, bundled to
/// `group-header-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAGroupHeaderDensityGalleryTests {
    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, busy: Bool = false) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: "~/fun/cmux", branch: "feat-cmux-next",
                             activity: busy ? .busy(progress: nil) : .idle)
        }
        var perf = SidebarGroup(id: GroupID("g-perf"), name: "Perf", color: .yellow, workspaces: [ws("tab", "Tab switch")])
        perf.parent = GroupID("g-panes")
        return [SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: GroupID("g-pinned"), name: "Pinned group", color: .green, isPinned: true,
                                workspaces: [ws("pin", "Pinned member")])),
            .group(SidebarGroup(id: GroupID("g-app"), name: "cmux-next app", color: .blue,
                                workspaces: [ws("cef", "Slimmer CEF bundle"), ws("home", "New Chief shows in Home")])),
            .group(SidebarGroup(id: GroupID("g-loading"), name: "Collapsed, loading", color: .red, isCollapsed: true,
                                workspaces: [ws("busy", "Busy", busy: true)])),
            .group(SidebarGroup(id: GroupID("g-panes"), name: "Panes & layout", color: .cyan, workspaces: [ws("split", "Split spring")])),
            .group(perf),
            .workspace(ws("loose", "Group header row height")),
            .workspace(ws("loose2", "Cloud Chief runner")),
        ])]
    }

    static func render(density: SidebarDensity, minimal: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let width: CGFloat = 260, height: CGFloat = 520
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input("Soft Blue")
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let model = SidebarModel(sections: sections())
        (model.minimal, model.expanded) = (minimal, density == .expanded)
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "group-header-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for minimal in [false, true] {
            for density in SidebarDensity.allCases {
                let image = try Self.render(density: density, minimal: minimal)
                images.append(image)
                try Self.write(image, to: out.appending(path: "\(minimal ? "minimal-" : "")\(density.rawValue).png"))
            }
        }
        // All six side by side: full mode on top (compact, comfortable, expanded), Minimal Mode below.
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: 3 * w + 2 * gap, height: 2 * h + gap, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % 3, row = i / 3
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try Self.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "group-header-gallery.tar", "group-header-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
