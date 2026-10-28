import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The trailing column's fixture (Leo 2026-10-28: "if you're hovering over a workspace or whatever, just don't show
/// the spinner ... why the fuck is it not aligned? Oh, because it's the inner tab thing"): `KindHarness` (every row
/// kind, groups at depths 0 to 2, inner tab rows that work or are unread) at rest, with a working row hovered and with
/// a loading header hovered, plus `geometry.json`: per row its accessibility identifier, kind, parent and depth, and
/// every drawn dot, spinner, chevron and hover control as view frames in the list's coordinates (not AX frames).
/// Artifact `sidebar-trailing-column-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct SidebarTrailingColumnGalleryTests {
    typealias T = SidebarTrailingColumnTests

    struct Item: Encodable {
        var what: String
        var listFrame: [CGFloat]
    }

    /// A drawn dot, spinner or chevron: its center x in the list, and its center y less its row's.
    struct Mark: Encodable {
        var what: String
        var centerX: CGFloat
        var dyFromRowCenter: CGFloat
    }

    struct Row: Encodable {
        var key: String
        var identifier: String
        var kind: String
        var parent: String?
        var depth: Int
        var hovered: Bool
        var listFrame: [CGFloat]
        var marks: [Mark]
        var controls: [Item]
    }

    /// How list points map onto the state's PNG. Every frame and center in `rows` is in SidebarListView points,
    /// origin at the list's top-left (`listIsFlipped` true) or bottom-left (false). The PNG draws the window's content
    /// view (`imagePoints`, top-left origin) at `backingScale` pixels per point; `listInImage` is the list's bounds in
    /// those image points, top-left origin, so an image pixel is (listInImage.x + x, listInImage.y + y) * scale.
    struct State: Encodable {
        var state: String
        var image: String
        var density: String
        var width: CGFloat
        var columnCenterX: CGFloat
        var listIsFlipped: Bool
        var imagePoints: [CGFloat]
        var imagePixels: [Int]
        var backingScale: CGFloat
        var listInImage: [CGFloat]
        var rows: [Row]
    }

    static func box(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height].map { ($0 * 100).rounded() / 100 } }

    /// Each group's and workspace's parent group, and each group's nesting depth, from the harness's model.
    static func parents(_ model: SidebarModel) -> (parent: [String: String], depth: [String: Int]) {
        var parent: [String: String] = [:], groupParent: [GroupID: GroupID] = [:]
        for section in model.sections {
            for case .group(let group) in section.nodes {
                if let up = group.parent { groupParent[group.id] = up; parent["group:\(group.id.rawValue)"] = "group:\(up.rawValue)" }
                for ws in group.workspaces { parent["workspace:\(ws.id.rawValue)"] = "group:\(group.id.rawValue)" }
            }
        }
        var depth: [String: Int] = [:]
        for (child, _) in groupParent {
            var d = 0, cursor: GroupID? = child
            while let up = cursor.flatMap({ groupParent[$0] }) { d += 1; cursor = up }
            depth["group:\(child.rawValue)"] = d
        }
        return (parent, depth)
    }

    static func describe(_ key: SidebarRowKey) -> (key: String, kind: String, parent: String?)? {
        switch key {
        case .workspace(let id): ("workspace:\(id.rawValue)", "workspace", nil)
        case .group(let id): ("group:\(id.rawValue)", "groupHeader", nil)
        case .tab(let ws, let tab): ("tab:\(ws.rawValue)/\(tab.rawValue)", "innerTab", "workspace:\(ws.rawValue)")
        default: nil
        }
    }

    static func export(_ h: T.KindHarness, state: String, density: SidebarDensity, image: CGImage, name: String) throws -> State {
        let (parent, groupDepth) = parents(h.model)
        // A group's nesting depth; a member one deeper than its group; a tab one deeper than its workspace.
        func depth(_ key: String) -> Int {
            if key.hasPrefix("group:") { return groupDepth[key] ?? 0 }
            if key.hasPrefix("tab:") { return depth("workspace:" + key.dropFirst(4).split(separator: "/")[0]) + 1 }
            return parent[key].map { depth($0) + 1 } ?? 0
        }
        var rows: [Row] = []
        for (key, view) in h.list.rowViews {
            guard let (name, kind, owner) = describe(key) else { continue }
            let up = owner ?? parent[name]
            let marks = T.marks(in: view, named: "", list: h.list).map {
                Mark(what: String($0.what.dropFirst()), centerX: $0.midX, dyFromRowCenter: $0.dy)
            }
            var controls: [(String, NSView)] = []
            if let row = view as? WorkspaceRowView {
                controls = [("close", row.closeButton), ("more", row.moreButton), ("pin", row.pinButton), ("disclosure", row.disclosureButton)]
            } else if let header = view as? GroupHeaderRowView {
                controls = [("more", header.moreButton), ("add", header.addButton)]
            }
            let shown = controls.filter { !$0.1.isHidden && T.drawnAlpha($0.1, below: h.list) > 0.01 }
                .map { Item(what: $0.0, listFrame: box(h.list.convert($0.1.frame, from: view))) }
            rows.append(Row(key: name, identifier: view.accessibilityIdentifier(), kind: kind, parent: up,
                            depth: depth(name),
                            hovered: (view as? SidebarRowView)?.isHovered ?? false,
                            listFrame: box(h.list.convert(view.bounds, from: view)), marks: marks, controls: shown))
        }
        rows.sort { $0.listFrame[1] < $1.listFrame[1] }
        let content = try #require(h.window.contentView)
        var inContent = content.convert(h.list.bounds, from: h.list)
        if !content.isFlipped { inContent.origin.y = content.bounds.height - inContent.maxY }
        return State(state: state, image: name, density: density.rawValue, width: h.sidebar.bounds.width, columnCenterX: try T.columnX(h),
                     listIsFlipped: h.list.isFlipped, imagePoints: [content.bounds.width, content.bounds.height],
                     imagePixels: [image.width, image.height], backingScale: CGFloat(image.width) / content.bounds.width,
                     listInImage: box(inContent), rows: rows)
    }

    static func render(_ h: T.KindHarness) throws -> CGImage {
        let root = try #require(h.window.contentView)
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderTheColumnAtRestAndOnHover() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-trailing-column-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var states: [State] = []
        for density in [SidebarDensity.compact, .comfortable] {
            try SidebarGroupRailAlignmentTests.with(density, .off) {
                let h = T.KindHarness(width: 300)
                defer { h.window.close() }
                h.window.appearance = NSAppearance(named: .darkAqua)
                let input = try AANestedGroupsGalleryTests.input("Soft Blue")
                _ = ThemeScope.app.store.apply(input)
                let scope = ThemeScope(level: .room)
                scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
                let content = try #require(h.window.contentView)
                content.wantsLayer = true
                scope.root(content)
                content.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
                let hovers: [(String, SidebarRowKey?)] = [("rest", nil), ("hover-working-row", .workspace(T.busy)),
                                                          ("hover-selected-row", .workspace(T.selected)),
                                                          ("hover-loading-header", .group(T.folded))]
                for (state, key) in hovers {
                    let row = key.flatMap { h.list.rowViews[$0] as? SidebarRowView }
                    row?.isHovered = true
                    defer { row?.isHovered = false; row?.layoutSubtreeIfNeeded() }
                    let image = try Self.render(h), name = "\(density.rawValue)-\(state).png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                    states.append(try Self.export(h, state: state, density: density, image: image, name: name))
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(states).write(to: out.appending(path: "geometry.json"))
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-trailing-column-gallery.tar", "sidebar-trailing-column-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
