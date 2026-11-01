import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import CmuxNextTestSupport
import Foundation
import Testing

/// A still of the real sidebar with one machine per link state (Leo, 2026-10-28: "you just get a
/// little green dot"): connected, connecting, reconnecting and offline, in Soft Blue dark. Written
/// to `machine-link-gallery/all.png`, bundled to `machine-link-gallery.tar` for
/// `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMachineLinkGalleryTests {
    static func sections() -> [SidebarSection] {
        let states: [(String, SidebarMachine.Status)] = [
            ("build-box", .connected), ("gpu-box", .connecting), ("agent-vm", .reconnecting), ("old-mini", .offline),
        ]
        return states.map { name, status in
            let machine = SidebarMachine(id: MachineID(name), name: name, kind: .ssh, status: status)
            let workspace = SidebarWorkspace(id: WorkspaceID("w-\(name)"), title: "Machine state feed", directory: "~/fun/cmux",
                                             branch: "feat-cmux-next", activity: .idle)
            return SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let width: CGFloat = 260, height: CGFloat = 260
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
        let list = SidebarListView(model: SidebarModel(sections: Self.sections()))
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

        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "machine-link-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "machine-link-gallery.tar", "machine-link-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
