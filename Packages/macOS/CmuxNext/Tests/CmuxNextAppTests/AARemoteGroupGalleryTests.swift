import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Remote groups drawn as sidebar groups (user 2026-10-31, Chief msg 19277: "it needs to look like a group in the
/// sidebar"): the real sidebar list with This Mac's rows, a connected remote group holding a subgroup, and an offline
/// one, in every ``SidebarHostGroupLook`` (``SidebarHostGroupLook/sectionHeader`` is the before), light and dark.
/// `CMUX_TEST_REQUIRE_GUI=1`; writes PNGs under `remote-group-gallery/` and `remote-group-gallery.tar` for
/// `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AARemoteGroupGalleryTests {
    static func ws(_ id: String, _ title: String, unread: UnreadState = .none, busy: Bool = false) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, unread: unread, activity: busy ? .busy(progress: nil) : .idle)
    }

    /// This Mac, `build-box` (connected, a `cmux-next` subgroup) and `studio-mac` (offline).
    static func sections(_ look: SidebarHostGroupLook) -> [SidebarSection] {
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: GroupID("g-home"), name: "Home & chat", color: .green, isCollapsed: false,
                                workspaces: [ws("replies", "Replies animation"), ws("compose", "Home compose", unread: .dot)])),
            .workspace(ws("scratch", "Scratch")),
        ])
        var sub = SidebarGroup(id: GroupID("g-next"), name: "cmux-next", color: .blue, isCollapsed: false,
                               workspaces: [ws("lock", "Session lock fix", busy: true), ws("setup", "Add Machine setup")])
        sub.parent = nil
        var remote = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("ssh-build-box"), name: "build-box", kind: .ssh)),
                                    nodes: [.workspace(ws("chief", "Chief brain")), .workspace(ws("logs", "Daemon logs")), .group(sub)])
        remote.isHostGroup = true
        var offline = SidebarSection(kind: .machine(SidebarMachine(id: MachineID("ssh-studio"), name: "studio-mac", kind: .ssh,
                                                                   status: .offline, detail: "Offline since 14:02")),
                                     nodes: [.workspace(ws("bench", "Bench runs"))])
        offline.isHostGroup = true
        return [local, remote, offline].map { look == .sectionHeader ? $0 : $0.wrappedAsHostGroup(look: look) }
    }

    static func render(_ look: SidebarHostGroupLook, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 288, height: CGFloat = 420
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        _ = ThemeScope.app.store.apply(try AANestedGroupsGalleryTests.input(theme))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: try AANestedGroupsGalleryTests.input(theme), animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let model = SidebarModel(sections: sections(look))
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsLayout = true; view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Every look but the before draws each remote machine as a group header row, never a section header.
    @Test func everyGroupLookDrawsTheMachineAsAGroupRow() {
        for look in SidebarHostGroupLook.allCases {
            // One list (the app's default): a remote group's header is its group row, never a section header.
            var options = SidebarLayoutOptions()
            options.flattensMachines = true
            let rows = SidebarLayout.make(sections: Self.sections(look), metrics: .standard, options: options).rows.map(\.key)
            let host = SidebarRowKey.group(SidebarGroup.hostGroupID(MachineID("ssh-build-box")))
            if look == .sectionHeader {
                #expect(rows.contains(.section(.machine(MachineID("ssh-build-box")))))
                #expect(!rows.contains(host))
            } else {
                #expect(rows.contains(host), "\(look)")
                #expect(!rows.contains(.section(.machine(MachineID("ssh-build-box")))), "\(look)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "remote-group-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [[CGImage]] = []
        for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
            var line: [CGImage] = []
            for look in SidebarHostGroupLook.allCases {
                let image = try Self.render(look, theme: theme, dark: dark)
                line.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.rawValue)-\(mode).png"))
            }
            lines.append(line)
        }
        let w = lines[0][0].width, h = lines[0][0].height, gap = 16
        let columns = lines[0].count, rows = lines.count
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: rows * h + (rows - 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (line, images) in lines.enumerated() {
            for (column, image) in images.enumerated() {
                ctx.draw(image, in: CGRect(x: column * (w + gap), y: (rows - 1 - line) * (h + gap), width: w, height: h))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "remote-group-gallery.tar", "remote-group-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
