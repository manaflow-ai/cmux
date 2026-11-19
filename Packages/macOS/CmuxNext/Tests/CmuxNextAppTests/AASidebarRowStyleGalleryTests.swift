import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the sidebar row restyle (`experiments.sidebarRowStyle`, taste build 7, 2026-11-19): the real
/// `SidebarView` at 300 x 720 pt with 21 workspaces in five project groups (two nested under "Panes & layout", two
/// collapsed), one long title that truncates, one pinned row and the selected row inside "cmux-next app", once per
/// ``SidebarRowStyle`` (`off` is the before; `capsule`, `bar`, `soft` the after), dark and light. Written under
/// `sidebar-row-style-gallery/` as `<appearance>-<style>.png` with `all.png` (one column per style, dark on top, light
/// below), plus a hover walk per style in dark (`hover-<style>-NN.png`: frame 00 hovers the "+ New workspace" row while
/// it shows, then the hover moves down six list rows one at a time, revealing each row's pin and close), and bundled
/// to `sidebar-row-style-gallery.tar` for `cmux-ci run --artifact`. Where ffmpeg is installed each walk is also
/// stitched to `hover-<style>.mp4`; without it the frames stay as they are.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarRowStyleGalleryTests {
    static let width: CGFloat = 300, height: CGFloat = 720
    static let selected = WorkspaceID("w-restyle")
    static let pinned = WorkspaceID("w-release")

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, busy: Bool = false, unread: Bool = false) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, unread: unread ? .dot : .none,
                             activity: busy ? .busy(progress: nil) : .idle)
        }
        var app = SidebarGroup(id: GroupID("g-app"), name: "cmux-next app", color: .blue, workspaces: [
            ws("restyle", "Sidebar row restyle", busy: true),
            ws("reopen", "Reopen closes all"),
            ws("long", "A very long workspace title that keeps going well past the sidebar's edge"),
            ws("update", "Update stuck Installing", busy: true),
            ws("align", "Group bar alignment", unread: true),
        ])
        app.icon = .emoji("😇")
        var perf = SidebarGroup(id: GroupID("g-perf"), name: "Perf", color: .yellow, workspaces: [
            ws("tab", "Tab switch"), ws("scroll", "Scroll jank"), ws("cold", "Cold launch"),
        ])
        perf.parent = GroupID("g-panes")
        var startup = SidebarGroup(id: GroupID("g-startup"), name: "Startup", color: .green, workspaces: [
            ws("dyld", "Dyld trace"), ws("prewarm", "Prewarm pages"),
        ])
        startup.parent = GroupID("g-perf")
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("inbox", "Inbox triage")),
            .workspace(ws("release", "Release checklist")),
            .group(app),
            .group(SidebarGroup(id: GroupID("g-panes"), name: "Panes & layout", color: .cyan, workspaces: [
                ws("split", "Split spring"), ws("zoom", "Zoom toggle"), ws("focus", "Pane focus ring"),
            ])),
            .group(perf),
            .group(startup),
            .group(SidebarGroup(id: GroupID("g-web"), name: "Website", color: .purple, isCollapsed: true, workspaces: [
                ws("landing", "Landing copy"), ws("docs", "Docs search"), ws("pricing", "Pricing page"),
            ])),
            .group(SidebarGroup(id: GroupID("g-lab"), name: "Experiments", color: .orange, isCollapsed: true, workspaces: [
                ws("proto", "Old prototype"),
            ])),
            .workspace(ws("ship", "Ship it", busy: true)),
        ])]
    }

    /// One real sidebar in a borderless window, in a Soft Blue theme, at one row style.
    @MainActor final class Stage {
        let window: NSWindow
        let root: NSView
        let sidebar: SidebarView

        init(style: SidebarRowStyle, dark: Bool) throws {
            _ = NSApplication.shared
            let w = AASidebarRowStyleGalleryTests.width, h = AASidebarRowStyleGalleryTests.height
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: w, height: h), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
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
            // The sidebar reads its own settings (the + row, the titlebar +); the rows read the shared ones, which the
            // caller set to the same style.
            let design = DesignSettings()
            design.sidebarRowStyle = style
            let model = SidebarModel(sections: AASidebarRowStyleGalleryTests.sections(), activeWorkspaceID: AASidebarRowStyleGalleryTests.selected)
            model.workspacePin = (isPinned: { $0 == AASidebarRowStyleGalleryTests.pinned }, toggle: { _ in })
            sidebar = SidebarView(model: model, design: design)
            sidebar.frame = root.bounds
            root.addSubview(sidebar)
            model.applyListPreferences(design.sidebarSections)
            window.orderFrontRegardless()
            sidebar.renderNow()
            sidebar.list.reload(animated: false)
            // The + row is made at the sidebar's first layout.
            root.layoutSubtreeIfNeeded()
        }

        /// The rows the hover walk visits: the first six list rows under the + row (headers and workspaces, top down).
        var walk: [SidebarRowKey] {
            Array(sidebar.list.displayed.rows.sorted { $0.y < $1.y }.map(\.key).filter {
                switch $0 {
                case .workspace, .group: true
                default: false
                }
            }.prefix(6))
        }

        /// Hovers `key` in the list (nil: no list row), and the + row when `newRow`.
        func hover(_ key: SidebarRowKey?, newRow: Bool = false) {
            sidebar.list.setHovered(key)
            sidebar.newWorkspaceRowView?.isHovered = newRow
        }

        func snapshot() throws -> CGImage {
            for view in AANestedGroupsGalleryTests.all(root) {
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return try #require(rep.cgImage)
        }

        func close() { window.close() }
    }

    /// Runs `body` with the shared settings at `style` (the rows read them) and motion off, restoring both after.
    static func with<T>(_ style: SidebarRowStyle, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.sidebarRowStyle
        DesignSettings.shared.sidebarRowStyle = style
        Motion.reduceMotionOverride = true
        defer {
            DesignSettings.shared.sidebarRowStyle = saved
            Motion.reduceMotionOverride = nil
        }
        return try body()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-row-style-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let styles = SidebarRowStyle.allCases
        var images: [CGImage] = []
        for dark in [true, false] {
            for style in styles {
                let image = try Self.with(style) {
                    let stage = try Stage(style: style, dark: dark)
                    defer { stage.close() }
                    return try stage.snapshot()
                }
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(style.rawValue).png"))
            }
        }
        let columns = styles.count
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: 2 * h + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))

        // The hover walk, dark: the + row first (while it shows), then six list rows one at a time.
        for style in styles {
            try Self.with(style) {
                let stage = try Stage(style: style, dark: true)
                defer { stage.close() }
                var frame = 0
                if style.isOn {
                    stage.hover(nil, newRow: true)
                    try AAGroupHeaderDensityGalleryTests.write(try stage.snapshot(), to: out.appending(path: Self.hoverName(style, frame)))
                }
                frame = 1
                let walk = stage.walk
                #expect(walk.count == 6, "the walk has six rows to hover")
                for key in walk {
                    stage.hover(key)
                    try AAGroupHeaderDensityGalleryTests.write(try stage.snapshot(), to: out.appending(path: Self.hoverName(style, frame)))
                    frame += 1
                }
            }
            Self.stitch(style, in: out)
        }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-row-style-gallery.tar", "sidebar-row-style-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    static func hoverName(_ style: SidebarRowStyle, _ frame: Int) -> String {
        "hover-\(style.rawValue)-\(String(format: "%02d", frame)).png"
    }

    /// Stitches a style's hover frames to `hover-<style>.mp4` at two frames a second when ffmpeg is installed; the
    /// frames stay either way, so a missing or failing ffmpeg is not a test failure.
    static func stitch(_ style: SidebarRowStyle, in dir: URL) {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpeg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let start = style.isOn ? 0 : 1
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.currentDirectoryURL = dir
        process.arguments = ["-y", "-loglevel", "error", "-framerate", "2", "-start_number", "\(start)",
                             "-i", "hover-\(style.rawValue)-%02d.png", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                             "hover-\(style.rawValue).mp4"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
