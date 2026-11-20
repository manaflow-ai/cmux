import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo and Lawrence 2026-10-14: no count numbers on NEXT sidebar rows ("maybe we can do unreads
/// like this", T3 Code's thread list). A row's state is one small glyph in the trailing slot, also
/// when the row has the user's icon or a favicon (Lawrence 2026-10-19: nothing but the icon on the
/// left); a row without one is text only (WORKSPACE-ROWS-NO-DEFAULT-ICON, Lawrence: no kind icon or
/// agent logo): a blue dot when unread, a grey ring while working, the waiting
/// and error glyphs when it needs the user, the most urgent first. No time draws on the right
/// unless `sidebar.showTimestamps` is on (`SidebarNoTimestampsTests`). The count reads in the row's hover card and its accessibility label.
@MainActor @Suite(.serialized) struct SidebarRowCornerBadgeTests {
    private static let agent = WorkspaceID("ws-agent")
    private static let terminal = WorkspaceID("ws-terminal")
    private static let failing = WorkspaceID("ws-failing")
    private static let custom = WorkspaceID("ws-custom")
    private static let now = Date()

    private static func sidebar(_ style: SidebarRowBadgeStyle? = nil, detailed: Bool = false) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let agentRow = SidebarWorkspace(id: agent, title: "cmux-next", lastActivity: now.addingTimeInterval(-180),
                                        kind: .harness, kindBrand: "claude", unread: .count(1), activity: .success, agentBrand: "claude")
        let terminalRow = SidebarWorkspace(id: terminal, title: "workspace-1", lastActivity: now.addingTimeInterval(-60),
                                           kind: .terminal, unread: .count(2))
        let failingRow = SidebarWorkspace(id: failing, title: "api", lastActivity: now.addingTimeInterval(-60),
                                          kind: .terminal, unread: .count(3), activity: .error)
        let customRow = SidebarWorkspace(id: custom, title: "notes", lastActivity: now.addingTimeInterval(-60),
                                         icon: .emoji("🦊"), kind: .terminal, unread: .count(1))
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(agentRow), .workspace(terminalRow), .workspace(failingRow),
                                                            .workspace(customRow)]),
        ])
        model.rowBadgeStyle = style
        model.detailedStatus = detailed
        let design = DesignSettings()
        design.sidebarSections.detailedStatusIcons = detailed
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    /// Every visible view of `type` under `row`, with its frame in the row's coordinates.
    private static func visible<T: NSView>(_ type: T.Type, in row: NSView) -> [(view: T, frame: NSRect)] {
        var found: [(T, NSRect)] = []
        func walk(_ view: NSView) {
            for child in view.subviews where !child.isHidden && child.alphaValue > 0 {
                if let match = child as? T, child.frame.width > 0 { found.append((match, row.convert(child.bounds, from: child))) }
                walk(child)
            }
        }
        walk(row)
        return found
    }

    /// The one badge glyph: right of the title, never on the icon (Lawrence 2026-10-19: nothing but
    /// the favicon or the user's icon in the leading slot), with or without an icon.
    private static func cornerBadge(_ row: WorkspaceRowView) throws -> StatusIndicatorView {
        let icon = row.icon.frame
        let badge = visible(StatusIndicatorView.self, in: row).first { _, frame in
            frame.minX > row.title.frame.minX && (row.icon.isHidden || !frame.intersects(icon))
        }
        return try #require(badge?.view, "no trailing badge: icon \(icon) hidden \(row.icon.isHidden)")
    }

    @Test func rowsAreTextOnlyUnlessTheUserSetAnIconAndDrawNoCountNumber() throws {
        let sidebar = Self.sidebar()
        for id in [Self.agent, Self.terminal, Self.failing, Self.custom] {
            let row = try Self.row(sidebar, id)
            if id == Self.custom {
                #expect(!row.icon.isHidden && row.icon.frame.width > 0, "\(id): the user's icon does not draw")
            } else {
                #expect(row.icon.isHidden || row.icon.frame.width == 0, "\(id): a kind icon or agent logo draws")
                #expect(row.debugIcon == nil, "\(id): debug icon \(row.debugIcon ?? "")")
            }
            #expect(Self.visible(UnreadBadgeView.self, in: row).isEmpty, "\(id): a count badge still draws")
            #expect(row.timeLabel.isHidden || row.timeLabel.stringValue.isEmpty, "\(id): a time draws by default (sidebar.showTimestamps)")
        }
    }

    /// With detailed status icons (`sidebar.detailedStatusIcons`); by default an error reads as
    /// Ready (`SidebarStatusSimpleTests`).
    @Test func theCornerBadgeSaysTheMostUrgentState() throws {
        let sidebar = Self.sidebar(detailed: true)
        // Leo 2026-11-01: the red warning should be larger, like ChatGPT's (~13 pt ink).
        // The error grows inside its existing cell, retaining its center and whole-point frame.
        let badge = try Self.cornerBadge(Self.row(sidebar, Self.failing))
        let frame = try Self.row(sidebar, Self.failing).convert(badge.bounds, from: badge)
        #expect(frame.width == 14 && frame.height == 14)
        let row = try Self.row(sidebar, Self.failing)
        let cell = row.convert(row.rowBadge.bounds, from: row.rowBadge)
        #expect(frame.midX == cell.midX && frame.midY == cell.midY)
        #expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded(), "off the pixel grid: \(frame)")
        #expect(try Self.cornerBadge(Self.row(sidebar, Self.agent)).state == .success, "unread: the blue dot")
        #expect(try Self.cornerBadge(Self.row(sidebar, Self.terminal)).state == .success, "unread: the blue dot")
        #expect(try Self.cornerBadge(Self.row(sidebar, Self.failing)).state == .error, "an error outranks unread")
        #expect(try Self.cornerBadge(Self.row(sidebar, Self.custom)).state == .success, "on the user's icon: the blue dot")
    }

    @Test func theCountReadsInTheHoverCardAndTheLabel() throws {
        let workspace = SidebarWorkspace(id: Self.failing, title: "api", kind: .terminal, unread: .count(3), activity: .error)
        let card = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Self.now)
        #expect(card.facts.contains { $0.text == Strings.unreadCount(3) })
        let row = try Self.row(Self.sidebar(), Self.failing)
        #expect(row.accessibilityLabel()?.contains(Strings.unreadCount(3)) == true)
    }

    /// Lawrence 2026-10-18 (screen recording): the spinner and the blue dot at a text-only row's end
    /// had "a weird background circle thing". A lone glyph in the trailing slot draws bare: no
    /// tonal chip and no cutout ring behind it, in either badge style, also on a row with the
    /// user's icon (its badge is in the trailing slot too, Lawrence 2026-10-19).
    @Test func aLoneTrailingGlyphHasNoDiscBehindIt() throws {
        var working = SidebarWorkspace(id: Self.terminal, title: "build", kind: .terminal, activity: .working)
        working.agentWorking = true // agent work shows only on a row whose agent is working
        let unread = SidebarWorkspace(id: Self.agent, title: "panes", kind: .terminal, unread: .count(1))
        let iconRow = SidebarWorkspace(id: Self.custom, title: "notes", icon: .emoji("🦊"), kind: .terminal, unread: .count(1))
        for style in [SidebarRowBadgeStyle.corner, .stack] {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(working), .workspace(unread), .workspace(iconRow)])])
            model.rowBadgeStyle = style
            let sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
            for id in [Self.terminal, Self.agent, Self.custom] {
                let badge = try Self.row(sidebar, id).rowBadge
                #expect(badge.states.count == 1, "\(style) \(id): \(badge.states)")
                #expect(badge.look == .plain, "\(style) \(id): \(badge.look)")
                #expect(!badge.drawsBackdrop, "\(style) \(id): a disc draws behind the glyph")
            }
        }
    }

    /// Leo's alternative (`sidebar.rowBadge` stack): one glyph per pending item in the trailing slot,
    /// the most urgent first, overlapping like an avatar stack, up to the stack size (five by
    /// default, `SidebarRowBadgeStackCapTests`); the tooltip says the count.
    @Test func theStackDrawsOneOverlappingGlyphPerItemMostUrgentFirst() throws {
        let row = try Self.row(Self.sidebar(.stack, detailed: true), Self.failing)
        let stack = try #require(Self.visible(RowBadgeView.self, in: row).first)
        #expect(stack.view.states == [.error, .success, .success, .success])
        #expect(stack.frame.minX > row.title.frame.minX, "the stack is in the trailing slot")
        let glyphs = Self.visible(StatusIndicatorView.self, in: stack.view).map(\.frame).sorted { $0.minX < $1.minX }
        #expect(glyphs.count == 4)
        for (left, right) in zip(glyphs, glyphs.dropFirst()) {
            // Whole glyphs (none hides another), on one center line ...
            #expect(right.minX >= left.maxX, "a glyph is covered: \(left) \(right)")
            #expect(abs(right.midY - left.midY) < 0.5, "glyphs share a center line")
        }
        // ... in chips that overlap like avatars.
        #expect(stack.view.preferredWidth < 4 * stack.view.cellSide)
        #expect(stack.view.themedToolTip?.contains(Strings.unreadCount(3)) == true)
    }
}
