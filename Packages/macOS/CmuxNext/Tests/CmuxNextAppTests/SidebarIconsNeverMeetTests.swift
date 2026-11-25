import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Leo 2026-11-22T21:56Z, on a tree parent's chevron with the blue dot drawn over the ⋮ beside it: "this too. fucking
/// overlapping icons. over 24 hours ago." No two icons in a sidebar row share a box: at the sidebar's narrowest width
/// and a few steps above, at rest, selected and hovered, pinned or not, with the unread dot, an unread count, the error
/// mark or the spinner, every close spot and badge style, on a tree parent (its chevron) and a plain row. The check is
/// pairwise: every two drawn icon frames of the row, intersected.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarIconsNeverMeetTests {
    static let parent = WorkspaceID("meet-parent"), child = WorkspaceID("meet-child"), plain = WorkspaceID("meet-plain")

    enum Marks: String, CaseIterable, CustomTestStringConvertible {
        case unreadDot, unreadCount, error, working, everything
        var testDescription: String { rawValue }
        var unread: UnreadState {
            switch self {
            case .unreadDot, .everything: .dot
            case .unreadCount: .count(3)
            default: .none
            }
        }
        var activity: StatusIndicatorState {
            switch self {
            case .error, .everything: .error
            case .working: .working(progress: nil)
            default: .idle
            }
        }
    }

    enum Pose: String, CaseIterable { case rest, selected, hovered, menuOpen }

    /// The narrowest sidebar, a couple of steps above it, and the default.
    static var widths: [CGFloat] {
        let narrowest = Metrics.sidebarMinWidth
        return [narrowest, narrowest + 20, narrowest + 60, 260]
    }

    /// A sidebar of a tree parent (whose child draws under it, so the parent has a chevron) and a plain row, both
    /// carrying `marks`, `width` wide.
    static func sidebar(_ marks: Marks, style: SidebarRowBadgeStyle, width: CGFloat, selected: WorkspaceID? = nil) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        func ws(_ id: WorkspaceID, _ title: String) -> SidebarWorkspace {
            SidebarWorkspace(id: id, title: title, unread: marks.unread, activity: marks.activity)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws(parent, "Coordinator of the overlap fixes")),
            .workspace(SidebarWorkspace(id: child, title: "Lane")),
            .workspace(ws(plain, "A plain workspace row")),
        ])], activeWorkspaceID: selected ?? child)
        model.rowBadgeStyle = style
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// Every icon `row` draws now, by name, in row coordinates (half a point of each edge ignored).
    static func drawnIcons(_ row: WorkspaceRowView) -> [(String, CGRect)] {
        let icons: [(String, NSView?)] = [
            ("close", row.closeSlot.made), ("more", row.moreSlot.made), ("pin", row.pinSlot.made),
            ("treeFold", row.treeFoldSlot.made), ("audio", row.audioSlot.made), ("drive", row.driveIndicator),
            ("rowBadge", row.rowBadge), ("unread", row.badge), ("activity", row.activity),
            ("agentMark", row.agentMarkVariant == .besideTitle ? nil : row.agentMark), ("keycap", row.keycap),
            ("pullRequests", row.pullRequests), ("rollUp", row.rollUp), ("pinMark", row.pinMark), ("muted", row.mutedMark), ("cloud", row.cloudMark),
            ("presence", row.presenceDots), ("tabCount", row.tabCount),
        ]
        return icons.compactMap { name, view in
            guard let view, !view.isHidden, view.frame.width > 0, view.frame.height > 0,
                  SidebarTrailingColumnTests.drawnAlpha(view, below: row) > 0.01 else { return nil }
            return (name, row.convert(view.bounds, from: view).insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The pairs of drawn icons whose boxes meet, as "a/b".
    static func meetings(_ icons: [(String, CGRect)]) -> [String] {
        var found: [String] = []
        for i in icons.indices {
            for j in icons.indices where j > i && icons[i].1.intersects(icons[j].1) {
                found.append("\(icons[i].0) \(icons[i].1.minX)...\(icons[i].1.maxX) / \(icons[j].0) \(icons[j].1.minX)...\(icons[j].1.maxX)")
            }
        }
        return found
    }

    /// Lays `row` out in `pose`.
    static func pose(_ row: WorkspaceRowView, _ pose: Pose) {
        row.isHovered = pose == .hovered
        row.showsMenu = pose == .menuOpen
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        // The display pass runs after the layout, as in the app (it once put marks back under the ✕).
        row.updateLayer()
    }

    static func withTree<T>(_ body: () throws -> T) rethrows -> T {
        SidebarSessionTree.shared.state = SidebarSessionTreeState(parents: [child: parent])
        defer { SidebarSessionTree.shared.state = nil }
        return try body()
    }

    /// Leo's row: a tree parent (its chevron open), pinned (its ⋮ on the column with no ✕), with the blue unread dot,
    /// hovered at the sidebar's narrowest width. The dot must not draw on the ⋮ or the chevron.
    @Test func leosChevronAndDotNeverMeet() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        try Self.withTree {
            for width in Self.widths {
                for pinned in [true, false] {
                    let (sidebar, window) = Self.sidebar(.unreadDot, style: .corner, width: width, selected: Self.parent)
                    defer { window.close() }
                    sidebar.list.model.workspacePin = (isPinned: { _ in pinned }, toggle: { _ in })
                    sidebar.list.contextMenuProvider = { _ in NSMenu() }
                    window.orderFrontRegardless()
                    sidebar.renderNow()
                    let row = try #require(sidebar.list.rowViews[.workspace(Self.parent)] as? WorkspaceRowView)
                    row.wire(Self.parent, in: sidebar.list)
                    try #require(row.treeFold != nil, "the parent row has no chevron")
                    Self.pose(row, .hovered)
                    let icons = Self.drawnIcons(row)
                    #expect(icons.contains { $0.0 == "treeFold" }, "width \(width): no chevron on the hovered parent")
                    #expect(Self.meetings(icons).isEmpty, "width \(width), pinned \(pinned): \(Self.meetings(icons))")
                }
            }
        }
    }

    /// Every row state at every width: no two drawn icons meet.
    @Test(arguments: Marks.allCases, SidebarRowBadgeStyle.allCases)
    func noTwoIconsMeetInAnyRowState(_ marks: Marks, _ style: SidebarRowBadgeStyle) throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        var offenders: [String] = []
        try Self.withTree {
            for spot in SidebarRowCloseSpot.allCases {
                try SidebarRowCloseSpotTests.withCloseSpot(spot) {
                    for width in Self.widths {
                        for pinned in [false, true] {
                            let (sidebar, window) = Self.sidebar(marks, style: style, width: width)
                            defer { window.close() }
                            sidebar.list.model.workspacePin = (isPinned: { _ in pinned }, toggle: { _ in })
                            sidebar.list.contextMenuProvider = { _ in NSMenu() }
                            window.orderFrontRegardless()
                            sidebar.renderNow()
                            for id in [Self.parent, Self.plain] {
                                let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                                row.wire(id, in: sidebar.list)
                                for pose in Pose.allCases {
                                    Self.pose(row, pose)
                                    for meeting in Self.meetings(Self.drawnIcons(row)) {
                                        offenders.append("\(spot) \(style) \(marks) w\(Int(width)) pinned \(pinned) \(id.rawValue) \(pose): \(meeting)")
                                    }
                                }
                                Self.pose(row, .rest)
                            }
                        }
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders.count) overlaps: \(offenders.prefix(12).joined(separator: "; "))")
    }

    /// A pinned workspace's tile (Pinned, a band row): its ⋮ and Unpin never share a box with the dot, the spinner, the
    /// count or the task count, at rest or revealed, at every width.
    @Test(arguments: [false, true])
    func aTilesIconsNeverMeet(_ unreadDot: Bool) throws {
        for width in Self.widths {
            let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
            var info = SidebarItemInfo(title: "Workspace", symbol: "terminal", badge: unreadDot ? nil : 3)
            info.workspace = CmuxNextSidebar.WorkspaceID("ws")
            info.unreadDot = unreadDot
            info.activity = .working(progress: nil)
            info.taskProgress = SidebarTaskProgress(done: 2, total: 9)
            view.onMore = {}
            view.onUnpin = {}
            view.isPinned = { true }
            view.configure(info, style: .list)
            for revealed in [false, true] {
                view.showsMenu = revealed
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                let icons: [(String, NSView?)] = [("more", view.hoverMore), ("unpin", view.hoverUnpin), ("rowBadge", view.rowBadge),
                                                  ("unread", view.badge), ("activity", view.activity), ("taskCount", view.taskCount)]
                let drawn: [(String, CGRect)] = icons.compactMap { name, v in
                    guard let v, !v.isHidden, v.frame.width > 0, v.alphaValue > 0.01 else { return nil }
                    return (name, v.frame.insetBy(dx: 0.5, dy: 0.5))
                }
                #expect(Self.meetings(drawn).isEmpty, "width \(width), revealed \(revealed): \(Self.meetings(drawn))")
            }
        }
    }

    // MARK: - Gallery

    static func render(_ marks: Marks, width: CGFloat, pose: Pose, pinned: Bool, dark: Bool) throws -> CGImage {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        return try withTree {
            let (sidebar, window) = Self.sidebar(marks, style: .corner, width: width, selected: pose == .selected ? Self.parent : nil)
            defer { window.close() }
            sidebar.list.model.workspacePin = (isPinned: { _ in pinned }, toggle: { _ in })
            sidebar.list.contextMenuProvider = { _ in NSMenu() }
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
            let row = try #require(sidebar.list.rowViews[.workspace(Self.parent)] as? WorkspaceRowView)
            row.wire(Self.parent, in: sidebar.list)
            row.isHovered = pose == .hovered
            row.showsMenu = pose == .menuOpen
            for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
            CATransaction.flush()
            #expect(Self.meetings(Self.drawnIcons(row)).isEmpty, "\(marks) w\(width) \(pose) pinned \(pinned): \(Self.meetings(Self.drawnIcons(row)))")
            let frame = row.convert(row.bounds, to: root)
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: frame))
            root.cacheDisplay(in: frame, to: rep)
            return try #require(rep.cgImage)
        }
    }

    /// Rows: each width, pinned or not, per mark set; columns: rest, selected, hovered, menu open (dark). Artifact
    /// `sidebar-icons-never-meet-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderTreeParentAtNarrowWidths() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-icons-never-meet-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for marks in [Marks.unreadDot, .everything] {
            for dark in [true, false] {
                var grid: [[CGImage]] = []
                for width in Self.widths {
                    for pinned in [true, false] {
                        var line: [CGImage] = []
                        for pose in Pose.allCases {
                            let image = try Self.render(marks, width: width, pose: pose, pinned: pinned, dark: dark)
                            let name = "\(marks.rawValue)-w\(Int(width))-\(pinned ? "pinned" : "unpinned")-\(pose.rawValue)-\(dark ? "dark" : "light").png"
                            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                            line.append(image)
                        }
                        grid.append(line)
                    }
                }
                let gap = 8
                let cellWidth = grid.flatMap { $0 }.map(\.width).max() ?? 1, cellHeight = grid.flatMap { $0 }.map(\.height).max() ?? 1
                let columns = Pose.allCases.count
                let width = (cellWidth + gap) * columns, height = (cellHeight + gap) * grid.count
                let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                for (r, line) in grid.enumerated() {
                    for (c, image) in line.enumerated() {
                        ctx.draw(image, in: CGRect(x: c * (cellWidth + gap), y: height - (r + 1) * (cellHeight + gap), width: image.width, height: image.height))
                    }
                }
                try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()),
                                                           to: out.appending(path: "all-\(marks.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-icons-never-meet-gallery.tar", "sidebar-icons-never-meet-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
