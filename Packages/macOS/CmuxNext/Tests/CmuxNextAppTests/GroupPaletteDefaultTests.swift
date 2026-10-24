import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxTheme
import Testing

/// Lawrence 2026-10-13: familiar group UI first. Tab and sidebar groups draw his
/// fixed group palette (the Chrome tab group colors of #15516) whatever the theme,
/// and a group header's more button opens his group editor (cx-rcby), not the
/// right-click menu. #18991 and #19179 had moved the colors onto the theme's ANSI
/// palette, and #19019 had pointed the more button at the full menu.
@MainActor @Suite(.serialized) struct GroupPaletteDefaultTests {
    /// Lawrence's palette: hue in degrees and relative chroma.
    static let hues: [GroupColor: (hue: CGFloat, chroma: CGFloat)] = [
        .grey: (0, 0), .blue: (214, 1), .red: (4, 1), .yellow: (46, 1), .green: (136, 0.9),
        .pink: (330, 0.95), .purple: (272, 0.9), .cyan: (186, 0.9), .orange: (24, 1),
    ]
    /// The colors new groups take, groups 1...7: the palette's order without grey and blue.
    static let order: [GroupColor] = [.red, .yellow, .green, .pink, .purple, .cyan, .orange]

    /// A palette color as Lawrence drew it: the color itself (`fill` false) or the
    /// background that carries a name, in its light or dark variant.
    static func lawrence(_ color: GroupColor, fill: Bool, dark: Bool) throws -> ThemeRGB {
        let (hue, chroma) = try #require(hues[color])
        let saturation: CGFloat = fill ? (dark ? 0.34 : 0.30) : (dark ? 0.40 : 0.42)
        let brightness: CGFloat = fill ? (dark ? 0.40 : 0.86) : (dark ? 0.68 : 0.64)
        let ns = try #require(NSColor(calibratedHue: hue / 360, saturation: saturation * chroma, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB))
        return ThemeRGB(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
    }

    static func rgb(_ color: CGColor?) throws -> ThemeRGB {
        let ns = try #require(color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        return ThemeRGB(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
    }

    static func same(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        abs(a.red - b.red) < 0.006 && abs(a.green - b.green) < 0.006 && abs(a.blue - b.blue) < 0.006
    }

    /// A room with its own terminal palette; `art` puts a wallpaper behind it.
    static func room(_ name: String, background: UInt32, foreground: UInt32, palette: [UInt32], art: Bool = false) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground),
                               palette: palette.map { ThemeRGB(hex: $0) })
        scope.setOverride(try #require(ThemeSpec(name)), input: input, animated: false)
        if art { scope.setBackdropSelection(.art(.vanGoghStarryNight)) }
        return scope
    }

    static func themes() throws -> [(String, ThemeScope)] {
        let dark: [UInt32] = [0x1A1A1A, 0xE0533D, 0x3FB950, 0xD29922, 0x3B82F6, 0xA371F7, 0x2DD4BF, 0xC9D1D9]
        let light: [UInt32] = [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781]
        return [
            ("dark", try room("Group Dark", background: 0x0E1116, foreground: 0xE6EDF3, palette: dark)),
            ("light", try room("Group Light", background: 0xFFFFFF, foreground: 0x1F2328, palette: light)),
            ("wallpaper", try room("Group Wallpaper", background: 0x2B1650, foreground: 0xF4E3FF, palette: dark.reversed(), art: true)),
        ]
    }

    @Test func newGroupsTakeLawrencesPaletteOrder() {
        var sections: [CmuxNextSidebar.SidebarSection] = []
        var tabs: [GroupColor] = []
        for expected in Self.order {
            let sidebar = SidebarGroupBand.newGroupColor(in: sections)
            #expect(sidebar == expected, "sidebar group \(sections.count + 1)")
            sections.append(CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: [
                .group(SidebarGroup(id: GroupID("g\(sections.count)"), name: "", color: sidebar, workspaces: [])),
            ]))
            let tab = TabGroupOrdering.nextColor(used: tabs)
            #expect(tab == expected, "tab group \(tabs.count + 1)")
            tabs.append(tab)
        }
        #expect(ScreenGroupCommands.nextColor(in: nil) == Self.order[0])
    }

    @Test func tabGroupChipsAndUnderlinesDrawLawrencesPaletteInEveryTheme() throws {
        for (name, scope) in try Self.themes() {
            let dark = scope.tokens.isDark
            for color in Self.order + [.blue, .grey] {
                let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "API", colorToken: color), memberCount: 2)
                chip.themeScope = scope
                let fill = try Self.rgb(chip.pill.backgroundColor), want = try Self.lawrence(color, fill: true, dark: dark)
                #expect(Self.same(fill, want), "\(name) \(color) chip: \(fill), want \(want)")

                let band = TabGroupBandCell(color: .palette(color))
                band.themeScope = scope
                let line = try Self.rgb(band.lineLayer.backgroundColor), swatch = try Self.lawrence(color, fill: false, dark: dark)
                #expect(Self.same(line, swatch), "\(name) \(color) underline: \(line), want \(swatch)")
            }
        }
    }

    /// The sidebar's groups 1...7 under each theme: the header bar is the palette's
    /// name background (moved only as far as its ink needs for 4.5:1), and the members'
    /// line the bar's color.
    @Test func sidebarGroupHeadersAndLinesDrawLawrencesPaletteInEveryTheme() throws {
        for (name, scope) in try Self.themes() {
            let (sidebar, ids) = try Self.sidebar(Self.order)
            scope.root(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            let dark = scope.tokens.isDark
            for (id, color) in zip(ids, Self.order) {
                let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
                header.layoutSubtreeIfNeeded()
                header.updateLayer()
                let bar = try #require(header.layer?.sublayers?.first { $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 })
                let drawn = try Self.rgb(bar.backgroundColor)
                let want = scope.tokens.chip(try Self.lawrence(color, fill: true, dark: dark), inks: .onColor).fill
                #expect(Self.same(drawn, want), "\(name) \(color) header: \(drawn), want \(want)")
            }
            // The members' line is the bar's exact color (Leo 2026-10-19: bar and line are one color).
            let lines = Self.views(GroupLineView.self, in: sidebar)
            #expect(!lines.isEmpty, "\(name): no members' line")
            for line in lines {
                line.updateLayer()
                let drawn = try Self.rgb(line.railShape.fillColor)
                let want = scope.tokens.chip(try Self.lawrence(line.color.token, fill: true, dark: dark), inks: .onColor).fill
                #expect(Self.same(drawn, want), "\(name) \(line.color.token) line: \(drawn), want the bar's \(want)")
            }
        }
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The header's more button opens the group editor (cx-rcby): the name, the color
    /// dots and Lawrence's rows in order; a right-click on the header opens it too.
    @Test(.enabled("the editor bubble is a window on screen") { await Self.hasDisplay() })
    func theMoreButtonOpensTheGroupEditorWithItsRowsInOrder() throws {
        let (sidebar, ids) = try Self.sidebar([.red])
        var menuAsked = false
        sidebar.contextMenuProvider = { _ in menuAsked = true; return nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sidebar.list.groupEditor.hide(); window.orderOut(nil) }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(ids[0])] as? GroupHeaderRowView)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()

        // The button's own action, not performClick: on macOS 27 performClick spins a nested event
        // loop and queues blocks that stop the current run loop, and one can run after that loop
        // ended and stop the test helper's main run loop, which exits the run with status 0.
        let more = header.moreButton
        #expect(more.sendAction(more.action, to: more.target), "the more button has no action")

        #expect(!menuAsked, "the more button showed the right-click menu")
        #expect(sidebar.list.groupEditor.shownGroup == ids[0], "the more button did not open the group editor")
        let content = try #require(sidebar.list.groupEditor.bubble?.contentView)
        let rows = Self.views(SidebarGroupEditorRow.self, in: content).map(\.item)
        // No More Group Actions row (Lawrence 2026-10-20): a right-click shows the flat menu, and
        // the editor offers Pin and Move to Top itself.
        #expect(rows.map(\.id) == ["workspaceGroup.newWorkspace", "workspaceGroup.moveToNewWindow", "workspaceGroup.closeWorkspaces",
                                   "workspaceGroup.togglePin", "workspaceGroup.moveToTop",
                                   "workspaceGroup.ungroup", "workspaceGroup.delete"])
        #expect(rows.map(\.title) == ["New Workspace in Group", "Move to New Window", "Close All in Group",
                                      "Pin Group", "Move to Top", "Ungroup", "Delete Group"])
    }

    /// A right-click on a group header shows the group's flat menu at once (Lawrence 2026-10-20:
    /// "right now I need to right-click and then go do more group actions"), not the editor.
    @Test func aRightClickOnAGroupHeaderShowsItsMenuNotTheEditor() throws {
        let (sidebar, ids) = try Self.sidebar([.red])
        let menu = NSMenu(title: "group")
        var asked: [SidebarContextTarget] = []
        sidebar.contextMenuProvider = { target in asked.append(target); return menu }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { sidebar.list.groupEditor.hide(); window.orderOut(nil) }
        window.contentView?.addSubview(sidebar)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(ids[0])] as? GroupHeaderRowView)
        let point = sidebar.list.convert(NSPoint(x: header.frame.midX, y: header.frame.midY), from: header.superview)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: sidebar.list.convert(point, to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(sidebar.list.menu(for: event) === menu, "a right-click on the header did not show the group's menu")
        #expect(asked == [.group(ids[0])])
        #expect(sidebar.list.groupEditor.shownGroup == nil, "a right-click opened the group editor")
    }

    // MARK: Fixtures

    /// A sidebar with one group per color, each holding one workspace.
    static func sidebar(_ colors: [GroupColor]) throws -> (SidebarView, [GroupID]) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: colors.indices.map { index in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: "ws-\(index)"), name: "w\(index)")
        }))
        let section = try #require(SidebarMapping.shared.sections(store.sidebarSections,
                                                                   machine: SidebarMachine(id: .local, name: "This Mac", kind: .local)).first)
        let ids = colors.indices.map { GroupID("grp-\($0)") }
        let nodes: [CmuxNextSidebar.SidebarNode] = zip(colors, section.workspaces).enumerated().map { index, pair in
            .group(SidebarGroup(id: ids[index], name: "Group \(index + 1)", color: pair.0, workspaces: [pair.1]))
        }
        let sidebar = SidebarView(model: SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: section.kind, nodes: nodes)]),
                                  design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, ids)
    }

    static func views<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { sub in ((sub as? View).map { [$0] } ?? []) + views(type, in: sub) }
    }
}
