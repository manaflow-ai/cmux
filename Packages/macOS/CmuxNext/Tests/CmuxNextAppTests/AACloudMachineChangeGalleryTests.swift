import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Before/after stills of a Cloud machine's sidebar header while cmux Cloud pauses, resumes or
/// deletes it (Leo 2026-10-29: "let's just get the cloud and its respective ui up to snuff").
/// Before, a pausing record read Paused (and offered Resume); after, the header names the change
/// on its way. The list, dark and light, This Mac above a Cloud machine with two workspaces.
/// `CMUX_TEST_REQUIRE_GUI=1`; writes `cloud-machine-change-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AACloudMachineChangeGalleryTests {
    static func sections(_ status: SidebarMachine.Status) -> [SidebarSection] {
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let cloudID = MachineID("vm_gallery0000000000000")
        let cloud = SidebarMachine(id: cloudID, name: "staging-vm", kind: .cloud, status: status)
        func ws(_ id: String, _ title: String, machine: MachineID) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("w-\(id)"), machineID: machine, title: title)
        }
        return [
            SidebarSection(kind: .machine(local), nodes: [.workspace(ws("local", "Slimmer CEF bundle", machine: .local))]),
            SidebarSection(kind: .machine(cloud), nodes: [
                .workspace(ws("api", "api server", machine: cloudID)), .workspace(ws("tests", "test run", machine: cloudID)),
            ]),
        ]
    }

    static func render(_ status: SidebarMachine.Status, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 200
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
        let list = SidebarListView(model: SidebarModel(sections: sections(status)))
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
        window.closeAfterTest()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "cloud-machine-change-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Before: what a pausing record showed (Paused). After: each change on its way.
        let variants: [(String, SidebarMachine.Status)] = [
            ("before-pausing-read-paused", .paused), ("after-pausing", .pausing), ("after-resuming", .resuming), ("after-deleting", .deleting),
        ]
        var images: [CGImage] = []
        for dark in [true, false] {
            for (name, status) in variants {
                let image = try Self.render(status, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(name).png"))
            }
        }
        let columns = variants.count
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
        tar.arguments = ["cf", "cloud-machine-change-gallery.tar", "cloud-machine-change-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
