import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// `sidebar.drawnMenus` (Leo 2026-11-19: "i think y'all also ought to emulate the things for context menu styling and
/// such maybne in those repos too and the layout and proportions as well"): the sidebar's row menu, opt-in, opens as a
/// ``GlassMenu`` the menu look can style, with the same rows, shortcuts and submenus as the system menu it replaces.
/// Off (the default) it is the system menu, as today.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarDrawnMenuGalleryTests {
    static let target = ActionTargetRef(kind: .workspace, id: "ws")

    /// Every action of `entries`, its submenus' too.
    static func actions(_ entries: [ContextMenuEntry]) -> [ActionID] {
        entries.flatMap { entry -> [ActionID] in
            switch entry {
            case .action(let id), .choices(let id): [id]
            case .submenu(let id, let inner): [id] + actions(inner)
            case .folder(_, let inner), .group(_, let inner): actions(inner)
            case .separator: []
            }
        }
    }

    /// The workspace row's menu with every action bound, as the app builds it, and its header installed.
    static func rowMenu(drawn: Bool) -> NSMenu {
        let registry = ActionRegistry.standard()
        for id in actions(registry.contextMenuEntries(for: .workspaceRow)) { registry.bind(id, invoke: { _ in }) }
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        MenuIdentityHeader.install(in: menu, registry: registry, target: target, name: "api", rename: "renameWorkspace", drawn: drawn)
        return menu
    }

    /// A row a GlassMenu draws for each row of the system menu: drawn, the header is not installed, so Rename… and the
    /// color submenu stay rows instead of a row view the GlassMenu would drop.
    @Test func theDrawnMenuKeepsEveryRow() throws {
        let system = Self.rowMenu(drawn: false), drawn = Self.rowMenu(drawn: true)
        #expect(system.items.first?.view is MenuIdentityHeaderView, "the system menu keeps its name and swatches header")
        #expect(drawn.items.allSatisfy { $0.view == nil }, "the drawn menu has no row view")
        let rows = GlassMenuRow.rows(of: drawn).compactMap(\.item)
        #expect(rows.contains { ActionRegistry.menuRun(of: $0)?.id == "renameWorkspace" }, "Rename… is a row")
        #expect(rows.contains { $0.submenu != nil }, "the submenus are rows")
        let titles = Set(rows.map(\.title))
        let systemRows = system.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.view == nil }
        for item in systemRows { #expect(titles.contains(item.title), "\(item.title) is missing from the drawn menu") }
        for item in rows where !item.keyEquivalent.isEmpty { #expect(GlassMenuRow.shortcut(item) != nil, "\(item.title) lost its shortcut") }
    }

    /// The menu drawn in `theme` with the row at `hover` highlighted and its submenu beside it, flush right of the
    /// menu and top aligned to the row, as GlassMenu places one.
    static func render(theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let menu = rowMenu(drawn: true)
        let list = GlassMenuListView(), rows = GlassMenuRow.rows(of: menu)
        list.load(rows)
        let size = list.fittingMenuSize()
        let hover = try #require(rows.firstIndex { $0.item?.submenu != nil })
        let submenu = try #require(rows[hover].item?.submenu)
        submenu.update()
        let child = GlassMenuListView()
        child.load(GlassMenuRow.rows(of: submenu))
        let childSize = child.fittingMenuSize()
        let margin: CGFloat = 24, gap: CGFloat = 4
        let width = margin * 2 + size.width + gap + childSize.width, height = margin * 2 + max(size.height, childSize.height + 200)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        // The page behind: the window's own background, so a light menu over a light page (and dark over dark) shows.
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        let panel = Glass.makeMenuPanel(content: list)
        panel.frame = NSRect(x: margin, y: height - margin - size.height, width: size.width, height: size.height)
        root.addSubview(panel)
        panel.layoutSubtreeIfNeeded()
        list.frame = panel.contentView.bounds
        list.layoutSubtreeIfNeeded()
        list.highlight(hover)
        // The hovered row in the root's coordinates is the anchor GlassMenu places the submenu by.
        let hovered = try #require(list.view(at: hover))
        let anchor = root.convert(hovered.convert(hovered.bounds, to: nil), from: nil)
        let side = Glass.makeMenuPanel(content: child)
        side.frame = PopupPlacement.sideBySideFrame(anchor: anchor, size: childSize, screen: root.bounds, gap: gap, margin: 0).frame
        root.addSubview(side)
        side.layoutSubtreeIfNeeded()
        child.frame = side.contentView.bounds
        child.layoutSubtreeIfNeeded()
        child.highlightFirst()
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot, out = root.appending(path: "sidebar-drawn-menu-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Today's theme, the Claude theme and a third, each light and dark: the panel over a page of its own lightness.
        let looks: [(String, String, Bool)] = [
            ("cmux-dark", "Soft Blue", true), ("cmux-light", "Soft Blue Light", false),
            ("claude-dark", "Claude Dark", true), ("claude-light", "Claude Light", false),
            ("apple-dark", "Apple System Colors", true), ("apple-light", "Apple System Colors Light", false),
        ]
        for (name, theme, dark) in looks {
            try AAGroupHeaderDensityGalleryTests.write(try Self.render(theme: theme, dark: dark), to: out.appending(path: "\(name).png"))
        }
        let rows = GlassMenuRow.rows(of: Self.rowMenu(drawn: true)).map { row in
            row.item.map { $0.title + (GlassMenuRow.shortcut($0).map { "  [\($0)]" } ?? "") + ($0.submenu == nil ? "" : " ›") } ?? "---"
        }
        try (rows.joined(separator: "\n") + "\n").write(to: out.appending(path: "menu-rows.txt"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-drawn-menu-gallery.tar", "sidebar-drawn-menu-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
