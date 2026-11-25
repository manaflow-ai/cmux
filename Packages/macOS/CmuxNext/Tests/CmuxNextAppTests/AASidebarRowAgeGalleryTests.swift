import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of thread rows with their age at the right end of the title line, as Codex's thread list draws
/// them: agent chat workspaces whose only time is their chat's (`SidebarWorkspace.chatActivity`). Four
/// variants, dark and light: `off` (the default, `sidebar.showTimestamps` off: no age, as before), `compact`
/// (timestamps on), `comfortable-folder` (timestamps on, with the Directory element as a second line) and
/// `expanded` (timestamps on, the expanded density's last-message line). Written under `sidebar-row-age-gallery/`
/// with `all.png` (dark on top, light below), bundled to `sidebar-row-age-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarRowAgeGalleryTests {
    enum Variant: String, CaseIterable {
        case off, compact, comfortableFolder = "comfortable-folder", expanded
    }

    static func sections(now: Date) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let calendar = Calendar.current
        func chat(_ id: String, _ title: String, minutesAgo: Int = 0, daysAgo: Int = 0, folder: String, message: String) -> SidebarWorkspace {
            var ws = SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: folder, kind: .harness)
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
            ws.chatActivity = daysAgo == 0 ? now.addingTimeInterval(TimeInterval(-60 * minutesAgo)) : day.addingTimeInterval(3600 * 10)
            ws.lastMessage = message
            return ws
        }
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(chat("bg", "Change background color", minutesAgo: 1, folder: "~/code/alldevneeds",
                            message: "Set the page background to blue in index.css")),
            .workspace(chat("onboard", "Review onboarding feedback", daysAgo: 1, folder: "~/code/clicksiq",
                            message: "Three themes stand out in the survey answers")),
            .workspace(chat("interviews", "Summarize customer interviews", daysAgo: 2, folder: "~/code/clicksiq",
                            message: "Drafted a one-page summary")),
            .workspace(chat("pricing", "Compare pricing page copy", daysAgo: 9, folder: "~/code/site",
                            message: "The new copy is shorter by a third")),
            .workspace(SidebarWorkspace(id: WorkspaceID("w-shell"), title: "Terminal with no activity", directory: "~/code/site")),
        ])]
    }

    static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let density: SidebarDensity = switch variant {
        case .off, .compact: .compact
        case .comfortableFolder: .comfortable
        case .expanded: .expanded
        }
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let width: CGFloat = 300, height: CGFloat = 340
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
        let model = SidebarModel(sections: sections(now: Date()))
        model.expanded = density == .expanded
        model.showsTimestamps = variant != .off
        if variant == .comfortableFolder {
            model.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.directory])))
        }
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
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
        let out = root.appending(path: "sidebar-row-age-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for variant in Variant.allCases {
                let image = try Self.render(variant, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(variant.rawValue).png"))
            }
        }
        let columns = Variant.allCases.count
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
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-row-age-gallery.tar", "sidebar-row-age-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
