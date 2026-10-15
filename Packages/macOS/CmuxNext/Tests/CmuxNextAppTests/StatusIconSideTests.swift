import AppKit
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// Leo and Lawrence's team call (2026-10-14): no kind icon and no corner badge on a sidebar row;
/// one status icon (working, needs input, done, error) on the left or the right of the row, and
/// tabs the same so rows and tabs match. Both are Debug Settings choices until promoted: the
/// `sidebar.rowBadge` Status icon style, and `sidebar.statusIconSide` for its side. Leo 2026-10-15:
/// the Status icon style is the default and no row or tab draws a kind icon (agent chat, terminal or
/// browser); a page's favicon is its own icon, not a kind icon, and stays on the left.
@MainActor @Suite(.serialized) struct StatusIconSideTests {
    private static let busy = WorkspaceID("ws-status-busy")
    private static let done = WorkspaceID("ws-status-done")
    private static let chat = WorkspaceID("ws-status-chat")
    private static let page = WorkspaceID("ws-status-page")

    // MARK: Debug Settings

    @Test func debugSettingsListsTheSideNextToTheRowBadgeAndTheStatusIconIsTheDefault() {
        let keys = SidebarTunables.all.map(\.key)
        #expect(keys.contains(SidebarStatusIconSide.tunable.key))
        #expect(SidebarStatusIconSide.tunable.defaultValue == .left)
        #expect(SidebarRowBadgeStyle.tunable.defaultValue == .status)
    }

    @Test func aDefaultAgentChatRowShowsNoChatIconAndItsStatusOnTheLeft() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarRowBadgeStyle.tunable.key, nil)
        TunableStore.shared.set(SidebarStatusIconSide.tunable.key, nil)
        SidebarTunablesWatch.shared.changed()
        let row = try Self.row(Self.sidebar(), Self.chat)
        #expect(row.icon.isHidden, "no chat icon")
        #expect(row.statusSide == .left)
        #expect(row.activity.frame.maxX <= row.title.frame.minX + WorkspaceRowView.labelInset)
    }

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func noRowDrawsAKindIcon(_ side: SidebarStatusIconSide) throws {
        try Self.withStatusLook(side) {
            let sidebar = Self.sidebar()
            for id in [Self.busy, Self.chat, Self.page] {
                let row = try Self.row(sidebar, id)
                #expect(row.icon.isHidden, "\(id) draws a kind icon")
            }
        }
    }

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func tabsFollowTheRowsStatusLook(_ side: SidebarStatusIconSide) throws {
        try Self.withStatusLook(side) {
            #expect(StatusIndicatorConfig.current.statusSide == side)
        }
        #expect(StatusIndicatorConfig.current.statusSide == .left, "by default tabs draw the status icon on the left, as rows do")
    }

    // MARK: Sidebar rows

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func aRowShowsOneStatusIconOnTheSettingsSideAndNoKindIcon(_ side: SidebarStatusIconSide) throws {
        try Self.withStatusLook(side) {
            let sidebar = Self.sidebar()
            let row = try Self.row(sidebar, Self.busy)
            #expect(row.icon.isHidden, "no kind icon")
            #expect(row.rowBadge.isHidden, "no corner badge")
            #expect(!row.activity.isHidden && row.activity.state == .error, "the most urgent state: \(row.activity.state)")
            let title = row.title.frame.minX + WorkspaceRowView.labelInset
            switch side {
            case .left:
                #expect(row.activity.frame.maxX <= title, "the icon \(row.activity.frame) sits before the title at \(title)")
            case .right:
                #expect(row.activity.frame.minX > row.bounds.midX, "the icon \(row.activity.frame) sits on the right")
            }
        }
    }

    @Test func unreadWorkShowsTheDoneIcon() throws {
        try Self.withStatusLook(.left) {
            let row = try Self.row(Self.sidebar(), Self.done)
            #expect(row.activity.state == .success)
            #expect(row.badge.isHidden, "the unread count gives way to the done icon")
        }
    }

    @Test func leftRowsKeepTheirTitlesOnOneColumn() throws {
        try Self.withStatusLook(.left) {
            let sidebar = Self.sidebar()
            let busy = try Self.row(sidebar, Self.busy), quiet = try Self.row(sidebar, WorkspaceID("ws-status-quiet"))
            #expect(abs(busy.title.frame.minX - quiet.title.frame.minX) < 0.5)
        }
    }

    // MARK: Tabs

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func aTabShowsItsStatusIconOnTheSameSide(_ side: SidebarStatusIconSide) throws {
        try Self.withStatusLook(side) {
            let cell = TabCell(item: TabItem(id: TabID("t"), title: "build", status: .needsInput))
            cell.frame = CGRect(x: 0, y: 0, width: 220, height: 30)
            cell.layoutLayers()
            let glyph = try #require(cell.statusGlyphLayer, "a needs-input tab draws a status icon")
            #expect(cell.badgeLayer == nil, "no dot on the icon's corner")
            let icon = cell.iconLayer.frame
            switch side {
            case .left:
                #expect(glyph.frame.maxX <= icon.minX, "the icon \(glyph.frame) sits before the tab icon \(icon)")
            case .right:
                #expect(glyph.frame.minX >= icon.maxX + Metrics.space2, "the icon \(glyph.frame) sits after the title, not on \(icon)")
            }
        }
    }

    @Test(arguments: [SidebarStatusIconSide.left, .right])
    func aTabDrawsNoKindIconAndABrowserTabKeepsItsFavicon(_ side: SidebarStatusIconSide) throws {
        try Self.withStatusLook(side) {
            for icon in [TabIcon.icon(.agentChat), .icon(.terminal), .agentMark("claude")] {
                var item = TabItem(id: TabID("t"), title: "fix the build", icon: icon, status: .needsInput)
                item.iconIsKind = true
                let cell = Self.tab(item)
                #expect(cell.iconLayer.contents == nil, "\(icon) draws its kind icon")
                let glyph = try #require(cell.statusGlyphLayer)
                let slot = cell.iconLayer.frame
                switch side {
                case .left:
                    #expect(abs(glyph.frame.midX - slot.midX) < 0.5, "the status icon \(glyph.frame) takes the icon's slot \(slot)")
                case .right:
                    #expect(cell.titleLayer.frame.minX <= slot.minX + 0.5, "the title \(cell.titleLayer.frame) starts where the icon was \(slot)")
                }
            }
            var page = TabItem(id: TabID("p"), title: "docs.cmux.com", icon: .image(try Self.favicon()), status: .needsInput)
            page.iconIsKind = true
            let browser = Self.tab(page)
            #expect(browser.iconLayer.contents != nil, "a browser tab keeps its favicon")
            if side == .left {
                let glyph = try #require(browser.statusGlyphLayer)
                #expect(glyph.frame.maxX <= browser.iconLayer.frame.minX, "the status icon sits before the favicon")
            }
        }
    }

    private static func tab(_ item: TabItem) -> TabCell {
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 220, height: 30)
        cell.layoutLayers()
        return cell
    }

    private static func favicon() throws -> TabImage {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return TabImage(try #require(context.makeImage()))
    }

    // MARK: Fixtures

    /// Runs `body` with the Status icon row badge on `side`, then restores today's look. The store is
    /// active without a file, so nothing is written; the tunables watch and the status config are
    /// refreshed right away, as the app does one main-actor hop later.
    private static func withStatusLook(_ side: SidebarStatusIconSide, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let style = SidebarRowBadgeStyle.tunable.key, sideKey = SidebarStatusIconSide.tunable.key
        try #require(TunableStore.shared.set(style, SidebarRowBadgeStyle.status.tunableValue) == SidebarRowBadgeStyle.status.tunableValue)
        try #require(TunableStore.shared.set(sideKey, side.tunableValue) == side.tunableValue)
        SidebarTunablesWatch.shared.changed()
        StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current)
        defer {
            TunableStore.shared.set(style, nil)
            TunableStore.shared.set(sideKey, nil)
            SidebarTunablesWatch.shared.changed()
            StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current)
        }
        try body()
    }

    /// A failing row with unread items, a row with unread done work, a quiet row, a working agent
    /// chat and a browser page without a favicon yet.
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = [
            CmuxNextSidebar.SidebarWorkspace(id: busy, title: "api", kind: .terminal, unread: .count(2), activity: .error),
            CmuxNextSidebar.SidebarWorkspace(id: done, title: "web", kind: .terminal, unread: .count(1)),
            CmuxNextSidebar.SidebarWorkspace(id: WorkspaceID("ws-status-quiet"), title: "docs", kind: .terminal),
            CmuxNextSidebar.SidebarWorkspace(id: chat, title: "fix the build", kind: .harness, activity: .working(progress: nil)),
            CmuxNextSidebar.SidebarWorkspace(id: page, title: "docs.cmux.com", kind: .browser),
        ]
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }
}
