import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Native design comparison, with synthetic data. The chosen header-only version is the live list;
/// the other two are gallery-only reconstructions, never product settings. Artifacts are 2x.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEmptyGroupGalleryTests {
    enum Version: String, CaseIterable { case placeholder, headerOnly, alwaysAdd }
    enum State: String, CaseIterable { case rest, hover, drop }

    static func render(_ version: Version, state: State, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (sidebar, window, _) = SidebarEmptyGroupAddButtonTests.sidebar()
        defer { window.close() }
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: sidebar.frame)
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        root.addSubview(sidebar)
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        sidebar.renderNow()
        let list = sidebar.list
        let group = SidebarEmptyGroupAddButtonTests.group
        let header = try #require(list.rowViews[.group(group)] as? GroupHeaderRowView)
        header.isHovered = state == .hover
        header.isDropTarget = state == .drop
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        if version == .placeholder {
            // Reconstruct the previous native member-sized row without restoring it to product layout.
            let height = SidebarLayoutMetrics.standard.height(for: WorkspaceRowContent())
            let gap = SidebarLayoutMetrics.standard.rowSpacing
            for (key, row) in list.rowViews where key != .group(group) && row.frame.minY >= header.frame.maxY {
                row.frame.origin.y += height + gap
            }
            let row = EmptyGroupRowView(key: .emptyGroup(group))
            row.onAdd = {}
            row.configure(groupID: group, groupName: "Sleep alarm")
            row.frame = NSRect(x: header.frame.minX, y: header.frame.maxY + gap, width: header.frame.width, height: height)
            list.addSubview(row)
            row.layoutSubtreeIfNeeded()
            row.displayIfNeeded()
        } else if version == .alwaysAdd {
            // Compare a permanent header + against the chosen reveal-on-hover control.
            header.addButton.isHidden = false
            header.addButton.alphaValue = 1
        }
        CATransaction.flush()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * 2),
                                               pixelsHigh: Int(root.bounds.height * 2), bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderThreeVersions() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-empty-group-gallery")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var html = "<meta charset='utf-8'><title>Empty group designs</title><style>body{font:16px system-ui}section{display:flex;gap:16px}img{width:280px;height:500px}figure{margin:0}</style><h1>Empty group designs</h1><p>Chosen: headerOnly. No extra row; + on hover; group highlight during a drop.</p>"
        for dark in [false, true] {
            for state in State.allCases {
                html += "<h2>\(dark ? "Dark" : "Light") — \(state.rawValue)</h2><section>"
                for version in Version.allCases {
                    let name = "\(version.rawValue)-\(state.rawValue)-\(dark ? "dark" : "light").png"
                    try AAGroupHeaderDensityGalleryTests.write(try Self.render(version, state: state, dark: dark), to: out.appending(path: name))
                    html += "<figure><figcaption>\(version.rawValue)</figcaption><img src='\(name)'></figure>"
                }
                html += "</section>"
            }
        }
        try html.write(to: out.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-empty-group-gallery.tar", "sidebar-empty-group-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
