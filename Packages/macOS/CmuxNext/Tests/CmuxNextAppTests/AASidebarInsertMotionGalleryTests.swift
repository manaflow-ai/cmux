import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Real sidebar fixtures for the four insert choices. Capture the window during `insert` for motion proof;
/// the PNGs are settled before/after states, not recordings of the transition.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarInsertMotionGalleryTests {
    static func sections(inserted: Bool) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let names = ["Home anchor"] + (inserted ? ["New workspace"] : []) + ["Editor", "Docs", "Terminal", "Review", "Preview"]
        return [SidebarSection(kind: .machine(machine), nodes: names.map {
            .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0))
        })]
    }

    static func render(_ root: NSView, to url: URL) throws {
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        try AAGroupHeaderDensityGalleryTests.write(try #require(rep.cgImage), to: url)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderMotionVariants() throws {
        _ = NSApplication.shared
        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "sidebar-insert-motion-gallery")
        let archive = packageRoot.appending(path: "sidebar-insert-motion-gallery.tar")
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let oldMotion = SidebarInsertMotion.tunable.value
        let oldKinds = DesignSettings.shared.enabledAnimations
        let oldReduceMotion = Motion.reduceMotionOverride
        defer {
            TunableStore.shared.set(SidebarInsertMotion.tunable.key, .choice(oldMotion.rawValue))
            DesignSettings.shared.enabledAnimations = oldKinds
            Motion.reduceMotionOverride = oldReduceMotion
        }
        DesignSettings.shared.enabledAnimations.insert(.newWorkspace)
        Motion.reduceMotionOverride = false
        for motion in SidebarInsertMotion.allCases {
            TunableStore.shared.set(SidebarInsertMotion.tunable.key, .choice(motion.rawValue))
            let model = SidebarModel(sections: Self.sections(inserted: false))
            let sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 420)
            let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.closeAfterTest() }
            window.title = motion.tunableTitle + (motion == .snap ? " (selected)" : "")
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = sidebar
            let input = try AANestedGroupsGalleryTests.input("Soft Blue")
            let scope = ThemeScope(level: .room)
            scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
            scope.root(sidebar)
            window.orderFrontRegardless()
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            try Self.render(sidebar, to: out.appending(path: "\(motion.rawValue)-before.png"))
            model.noteUserIntent()
            model.sections = Self.sections(inserted: true)
            sidebar.list.reload(animated: true)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Motion.sidebar.spring(motion.token).settlingTime() + 0.1))
            try Self.render(sidebar, to: out.appending(path: "\(motion.rawValue)-after.png"))
        }
        try "Selected: snap. Existing rows land immediately; only the new row fades. PNGs show settled states.\n"
            .write(to: out.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", archive.lastPathComponent, out.lastPathComponent]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        print("Sidebar insert gallery: \(out.path)")
    }
}
