import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Gallery coverage for every row indicator at the full and narrow sidebar
/// widths. The same rows are rendered at both widths because seen state is
/// shared above the layout, rather than implemented by a width-specific view.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStatusSeenGalleryTests {
    static let states: [(String, StatusIndicatorState, UnreadState)] = [
        ("error", .error, .none),
        ("waiting", .waiting, .none),
        ("busy", .busy(progress: nil), .none),
        ("paused", .paused(progress: nil), .none),
        ("working", .working, .none),
        ("success", .success, .none),
        ("unread", .idle, .dot),
    ]

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = states.map { name, activity, unread in
            SidebarWorkspace(id: WorkspaceID("seen-\(name)"), title: name.capitalized, unread: unread, activity: activity)
        }
        return [SidebarSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))]
    }

    static func render(width: CGFloat) throws -> CGImage {
        _ = NSApplication.shared
        let height: CGFloat = 220
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = SidebarView(model: SidebarModel(sections: sections()), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = sidebar
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(sidebar) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderEveryStatusAtFullAndNarrowWidths() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-status-seen-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, width) in [("full", CGFloat(320)), ("narrow", CGFloat(196))] {
            try AAGroupHeaderDensityGalleryTests.write(Self.render(width: width), to: out.appending(path: "\(name).png"))
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-status-seen-gallery.tar", "sidebar-status-seen-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
