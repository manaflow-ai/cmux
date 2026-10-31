import AppKit
import CmuxTheme
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-23: "home unread indicator should just be blue dot instead". The sidebar's Home
/// row showed Home's unread conversations as a grey count chip ("1"). It now shows the blue unread
/// dot of a workspace row: the same glyph (the shared indicator's done dot, `Palette.notificationBlue`),
/// the same size, on the same trailing column (the group header chevron's x), at every sidebar
/// density, in light and dark. Each case prints a `HOMEDOT|` line so a fleet log shows the numbers.
@MainActor @Suite(.serialized)
struct HomeUnreadBlueDotTests {
    static let home = LayoutItemID("itm_home")
    static let unreadWorkspace = WorkspaceID("ws-unread")
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    /// The Home item counts nothing: it carries the dot while anything in Home is unread.
    @Test(arguments: [LayoutItemRef.builtIn(.home), SidebarLayoutDocument.homeRef])
    func homeCarriesADotNotACount(_ ref: LayoutItemRef) {
        let item = LayoutItem(id: Self.home, ref: ref)
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        let unread = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 3)[item.id]
        #expect(unread?.unreadDot == true, "Home with 3 unread conversations draws no dot")
        #expect(unread?.badge == nil, "Home with 3 unread conversations still draws a count \(String(describing: unread?.badge))")
        let read = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 0)[item.id]
        #expect(read?.unreadDot == false && read?.badge == nil, "Home with nothing unread shows an indicator")
    }

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let scope = ThemeScope(level: .room)
        var list: SidebarListView { sidebar.list }

        init(width: CGFloat, dark: Bool) {
            _ = NSApplication.shared
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let item = LayoutItem(id: HomeUnreadBlueDotTests.home, ref: SidebarLayoutDocument.homeRef)
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [item])
            let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
            let nodes: [SidebarNode] = [
                .workspace(SidebarWorkspace(id: HomeUnreadBlueDotTests.unreadWorkspace, title: "unread", unread: .dot)),
                .workspace(SidebarWorkspace(id: WorkspaceID("ws-read"), title: "read")),
            ]
            model = SidebarModel(sections: [block, CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
            let layout = SidebarLayoutDocument(sections: [top])
            model.layout = layout
            model.itemInfo = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 3)
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                           adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // A plain dark or light theme, so each appearance draws in its own palette.
            var input = dark ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
                : ThemeInput(background: ThemeRGB(hex: 0xF4F4F4), foreground: ThemeRGB(hex: 0x1E1E1E))
            input.accentColor = ThemeRGB(hex: 0x3B82F6)
            if let spec = ThemeSpec(dark ? "Home Dot Dark" : "Home Dot Light") { scope.setOverride(spec, input: input, animated: false) }
            scope.adopt(window)
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = scope.perform { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        }

        func homeRow() throws -> SidebarItemRowView {
            let block = try #require(list.rowViews[HomeUnreadBlueDotTests.topKey] as? SidebarBlockRowView, "no top block")
            let row = try #require(block.region.itemViews[HomeUnreadBlueDotTests.home], "no Home row")
            row.layoutSubtreeIfNeeded()
            return row
        }

        func workspaceRow() throws -> WorkspaceRowView {
            let row = try #require(list.rowViews[.workspace(HomeUnreadBlueDotTests.unreadWorkspace)] as? WorkspaceRowView, "no unread workspace row")
            row.layoutSubtreeIfNeeded()
            return row
        }

        /// The window's content as it draws.
        func render() -> NSBitmapImageRep? {
            guard let content = window.contentView else { return nil }
            func redraw(_ view: NSView) { view.needsDisplay = true; view.displayIfNeeded(); view.subviews.forEach(redraw) }
            redraw(content)
            CATransaction.flush()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
            content.cacheDisplay(in: content.bounds, to: rep)
            return rep
        }

        /// The color drawn at `point` (list coordinates).
        func color(at point: NSPoint, in rep: NSBitmapImageRep) -> NSColor? {
            guard let content = window.contentView else { return nil }
            let p = content.convert(point, from: list)
            let scale = CGFloat(rep.pixelsWide) / content.bounds.width
            let top = content.isFlipped ? p.y : content.bounds.height - p.y
            return rep.colorAt(x: Int(p.x * scale), y: Int(top * scale))?.usingColorSpace(.sRGB)
        }
    }

    /// The one visible row badge of `view` and its glyph frame in the list's coordinates.
    private static func dot(in view: NSView, list: SidebarListView) -> (RowBadgeView, CGRect)? {
        guard let badge = view.subviews.compactMap({ $0 as? RowBadgeView }).first(where: { !$0.isHidden }),
              let glyph = badge.glyphFrames.first else { return nil }
        return (badge, list.convert(glyph, from: badge))
    }

    nonisolated static let cases: [(SidebarDensity, Bool)] = SidebarDensity.allCases.flatMap { [($0, false), ($0, true)] }

    @Test(arguments: cases)
    func homeDrawsTheWorkspaceRowsBlueDot(_ density: SidebarDensity, _ dark: Bool) throws {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let label = "\(density.rawValue)/\(dark ? "dark" : "light")"
        let h = Harness(width: 260, dark: dark)
        defer { h.window.close() }
        let home = try h.homeRow(), workspace = try h.workspaceRow()
        #expect(home.badge.isHidden, "\(label): Home still draws its count chip (\(home.badge.state))")
        let (wsBadge, wsGlyph) = try #require(Self.dot(in: workspace, list: h.list), "\(label): the unread workspace row draws no dot")
        let (homeBadge, homeGlyph) = try #require(Self.dot(in: home, list: h.list), "\(label): Home draws no blue dot")
        #expect(homeBadge.states == wsBadge.states, "\(label): Home's dot is \(homeBadge.states), a workspace's \(wsBadge.states)")
        #expect(homeBadge.look == wsBadge.look, "\(label): Home's dot look \(homeBadge.look), a workspace's \(wsBadge.look)")
        #expect(abs(homeGlyph.width - wsGlyph.width) < 0.5 && abs(homeGlyph.height - wsGlyph.height) < 0.5,
                "\(label): Home's dot is \(homeGlyph.size), a workspace's \(wsGlyph.size)")
        #expect(abs(homeGlyph.midX - wsGlyph.midX) < 0.5, "\(label): Home's dot centers at x \(homeGlyph.midX), a workspace's at \(wsGlyph.midX)")
        let homeFrame = h.list.convert(home.bounds, from: home)
        #expect(abs(homeGlyph.midY - homeFrame.midY) < 0.75, "\(label): Home's dot is not centered on its row (\(homeGlyph.midY) vs \(homeFrame.midY))")
        // The title ends before the dot.
        #expect(h.list.convert(home.title.frame, from: home).maxX <= homeGlyph.minX, "\(label): Home's title runs into its dot")
        // Drawn in the workspace dot's blue.
        let rep = try #require(h.render())
        let homeInk = try #require(h.color(at: NSPoint(x: homeGlyph.midX, y: homeGlyph.midY), in: rep))
        let wsInk = try #require(h.color(at: NSPoint(x: wsGlyph.midX, y: wsGlyph.midY), in: rep))
        print("HOMEDOT|\(label)|home \(homeGlyph)|workspace \(wsGlyph)|homeInk \(homeInk)|wsInk \(wsInk)")
        // The render is in the display's color space, so the dot is compared with the workspace
        // dot drawn beside it (the same blue by construction), and must read as clearly blue.
        #expect(abs(homeInk.redComponent - wsInk.redComponent) < 0.02 && abs(homeInk.greenComponent - wsInk.greenComponent) < 0.02
                && abs(homeInk.blueComponent - wsInk.blueComponent) < 0.02, "\(label): Home's dot is \(homeInk), a workspace's \(wsInk)")
        #expect(homeInk.blueComponent > 0.8 && homeInk.blueComponent - homeInk.redComponent > 0.5,
                "\(label): Home's dot center \(homeInk) is not the unread blue")
    }

    /// Icon looks have no trailing column: the dot sits on the glyph's corner, in the same blue.
    @Test(arguments: [SidebarItemRowView.Style.tile, .icon, .favorite])
    func iconLooksDotTheGlyphInBlue(_ style: SidebarItemRowView.Style) throws {
        let item = LayoutItem(id: Self.home, ref: SidebarLayoutDocument.homeRef)
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        let info = try #require(SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 3)[item.id])
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 56, height: 52))
        row.configure(info, style: style)
        row.layoutSubtreeIfNeeded()
        row.badge.updateLayer()
        #expect(!row.badge.isHidden && row.badge.state == .dot, "\(style): Home draws no dot on its glyph")
        let fill = try #require(row.badge.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        // Lawrence msg 11983: the sidebar's unread blue is the system blue.
        var resolved: NSColor?
        row.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = Palette.statusUnread.usingColorSpace(.sRGB) }
        let blue = try #require(resolved)
        #expect(abs(fill.redComponent - blue.redComponent) < 0.01 && abs(fill.blueComponent - blue.blueComponent) < 0.01,
                "\(style): Home's glyph dot is \(fill), not the unread blue")
    }
}
