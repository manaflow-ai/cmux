import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Before and after stills of Reveal Workspace in Sidebar (Lawrence msg 20167: "we need a cmd shift p command like
/// focus in sidebar/scroll to in sidebar which is im in a workspaces and i want to see it in sidebar so i know where
/// it is"), light and dark. Before: the current workspace, iOS TestFlight, sits in the collapsed group Nightly & CI
/// inside the collapsed group Release, below the rows in view. After: the action's one path ran
/// (`SidebarView.revealWorkspace`), the groups are open, the row is in the middle of the list and its flash shows. Written under
/// `reveal-in-sidebar-gallery/` with `sheet.png` (Before | After, dark on top, light below), bundled to
/// `reveal-in-sidebar-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AARevealInSidebarGalleryTests {
    static let current = WorkspaceID("w-testflight")

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String, busy: Bool = false) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, activity: busy ? .busy(progress: nil) : .idle)
        }
        let above = [
            ws("cef", "Slimmer CEF bundle", busy: true), ws("readme", "README pass"), ws("split", "Split spring"),
            ws("cmd-d", "Cmd-D in Home"), ws("resize", "Column resize"), ws("zoom", "Zoom jank"), ws("tabs", "Tab switch"),
            ws("idle", "Idle CPU", busy: true), ws("drag", "Pane drag"), ws("daemon", "Daemon latency"), ws("rex", "Rex perf"),
            ws("scroll", "Scroll jank"), ws("launch", "Cold launch"), ws("icons", "Icon pass"),
        ].map(SidebarNode.workspace)
        let release = SidebarGroup(id: GroupID("g-release"), name: "Release", color: .green, isCollapsed: true,
                                   workspaces: [ws("notes", "Release notes"), ws("changelog", "Changelog draft")])
        var nightly = SidebarGroup(id: GroupID("g-nightly"), name: "Nightly & CI", color: .red, isCollapsed: true,
                                   workspaces: [ws("builder", "Nightly builder Mac"), ws("testflight", "iOS TestFlight", busy: true)])
        nightly.parent = release.id
        let below = [
            ws("docs", "Docs sweep"), ws("api", "API cleanup"), ws("login", "Cloud sign-in"), ws("flaky", "Flaky test hunt"),
            ws("settings", "Settings pass"), ws("shrink", "Shrink large files"), ws("hover", "Hover cards"), ws("scratch", "Scratch"),
        ].map(SidebarNode.workspace)
        return [SidebarSection(kind: .machine(machine), nodes: above + [.group(release), .group(nightly)] + below)]
    }

    /// The sidebar before (`reveal` false) or after Reveal Workspace in Sidebar ran.
    static func render(reveal: Bool, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 460
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
        let model = SidebarModel(sections: sections(), activeWorkspaceID: current)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        if reveal {
            #expect(sidebar.revealWorkspace(current))
            #expect(sidebar.list.revealFlash?.key == .workspace(current))
        }
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        // The flash at its brightest (its animation holds the layer's own opacity at 0 between blinks).
        if let flash = sidebar.list.revealFlash?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flash.opacity = 1
            CATransaction.commit()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        sidebar.list.revealFlash?.remove()
        window.close()
        return image
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true // the scroll lands in one frame
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "reveal-in-sidebar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for reveal in [false, true] {
                let image = try Self.render(reveal: reveal, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(reveal ? "after" : "before")-\(dark ? "dark" : "light").png"))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(images), to: out.appending(path: "sheet.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "reveal-in-sidebar-gallery.tar", "reveal-in-sidebar-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    /// Before | After, dark on top and light below, each column titled.
    static func sheet(_ images: [CGImage]) throws -> CGImage {
        let w = images[0].width, h = images[0].height, gap = 24, title = 56
        let ctx = try #require(CGContext(data: nil, width: 2 * w + 3 * gap, height: title + 2 * h + 3 * gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % 2, row = i / 2
            ctx.draw(image, in: CGRect(x: gap + col * (w + gap), y: gap + (1 - row) * (h + gap), width: w, height: h))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.preferredFont(forTextStyle: .largeTitle)
        for (col, text) in ["Before", "After"].enumerated() {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: gap + col * (w + gap), y: 2 * h + 3 * gap + 10))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(ctx.makeImage())
    }
}
