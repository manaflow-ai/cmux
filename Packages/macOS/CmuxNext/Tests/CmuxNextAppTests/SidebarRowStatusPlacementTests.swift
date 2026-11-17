import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// `sidebar.workspaceRow.statusPlacement` (Lawrence: "for customization make it possible to turn
/// our sidebar into" a minimal session list). `leading` draws the row's status mark (working,
/// blocked, done, error) in the leading icon slot before the title, and keeps that slot while the
/// row is idle, so the title's x never moves as work starts or stops. `trailing`, the default,
/// keeps the mark on the trailing column as before.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowStatusPlacementTests {
    private static let width: CGFloat = 320

    /// The states a row's mark says, idle first.
    private static let states: [(name: String, activity: StatusIndicatorState, unread: UnreadState)] = [
        ("idle", .idle, .none),
        ("working", .working(progress: nil), .none),
        ("blocked", .waiting(kind: .permission), .none),
        ("done", .success, .dot),
        ("error", .error, .none),
    ]

    private static func workspace(_ activity: StatusIndicatorState, unread: UnreadState, icon: WorkspaceIcon? = nil) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "Fix the build", lastActivity: Date(),
                                  agentWorking: activity.isWorking, activity: activity)
        ws.unread = unread
        ws.icon = icon
        return ws
    }

    /// The row the list draws for `ws` under `placement`, configured and laid out in a window.
    private static func row(_ ws: SidebarWorkspace, placement: WorkspaceRowStatusPlacement,
                            badgeStyle: SidebarRowBadgeStyle = .corner) -> (WorkspaceRowView, NSWindow) {
        var options = SidebarLayoutOptions()
        options.workspaceRow.statusPlacement = placement
        let content = options.rowContent(ws, machine: nil)
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        let view = WorkspaceRowView(key: row.key)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        view.configure(ws, row: row, badgeStyle: badgeStyle)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @Test func trailingIsTheDefault() {
        #expect(SidebarLayoutOptions().workspaceRow.statusPlacement == .trailing)
        let ws = Self.workspace(.working(progress: nil), unread: .none)
        #expect(SidebarLayoutOptions().rowContent(ws, machine: nil).statusLeads == false)
    }

    @Test(arguments: [SidebarRowBadgeStyle.corner, .stack, .trailing])
    func leadingPutsTheMarkBeforeTheTitleAndKeepsTheTitlesX(_ style: SidebarRowBadgeStyle) {
        var titleXs: [String: CGFloat] = [:]
        for state in Self.states {
            let (view, window) = Self.row(Self.workspace(state.activity, unread: state.unread), placement: .leading, badgeStyle: style)
            defer { window.close() }
            titleXs[state.name] = view.title.frame.minX
            guard state.activity != .idle else {
                #expect(view.leadingStatusMark == nil, "an idle row's slot stays empty")
                continue
            }
            let mark = view.leadingStatusMark
            #expect(mark != nil, "\(state.name): no leading mark")
            guard let mark else { continue }
            #expect(!mark.isHidden)
            #expect(mark.frame.maxX <= view.title.frame.minX, "\(state.name): the mark \(mark.frame) runs into the title \(view.title.frame)")
            // Nothing of the status stays on the trailing column.
            let column = SidebarStyle.columns(rowWidth: Self.width).trailingCenter()
            for status in [view.rowBadge, view.activity] as [NSView] where !status.isHidden && status !== mark {
                #expect(status.frame.maxX < column, "\(state.name): \(status) still on the trailing column")
            }
        }
        let idle = titleXs["idle"]
        #expect(idle != nil)
        for (name, x) in titleXs { #expect(x == idle, "\(name): the title moved from \(idle ?? -1) to \(x)") }
    }

    @Test func leadingTakesTheIconsPlaceOnlyWhileTheStatusShows() {
        let icon = WorkspaceIcon.symbol("star")
        let (idle, idleWindow) = Self.row(Self.workspace(.idle, unread: .none, icon: icon), placement: .leading)
        defer { idleWindow.close() }
        let (working, workingWindow) = Self.row(Self.workspace(.working(progress: nil), unread: .none, icon: icon), placement: .leading)
        defer { workingWindow.close() }
        #expect(!idle.icon.isHidden, "an idle row shows its icon in the slot")
        #expect(working.icon.isHidden, "the status mark takes the icon's slot")
        #expect(working.leadingStatusMark != nil)
        #expect(idle.title.frame.minX == working.title.frame.minX)
    }

    @Test func leadingReservesTheSlotOnATextOnlyRow() {
        let (leading, leadingWindow) = Self.row(Self.workspace(.idle, unread: .none), placement: .leading)
        defer { leadingWindow.close() }
        let (iconRow, iconWindow) = Self.row(Self.workspace(.idle, unread: .none, icon: .symbol("star")), placement: .trailing)
        defer { iconWindow.close() }
        // The idle text-only row's title starts where a row with an icon starts its title.
        #expect(leading.title.frame.minX == iconRow.title.frame.minX)
    }

    @Test(arguments: [SidebarRowBadgeStyle.corner, .stack, .trailing])
    func trailingKeepsTheMarkOnTheTrailingColumn(_ style: SidebarRowBadgeStyle) {
        var titleXs: Set<CGFloat> = []
        for state in Self.states {
            let (view, window) = Self.row(Self.workspace(state.activity, unread: state.unread), placement: .trailing, badgeStyle: style)
            defer { window.close() }
            #expect(view.leadingStatusMark == nil)
            titleXs.insert(view.title.frame.minX)
            guard state.activity != .idle else { continue }
            let marks = ([view.rowBadge, view.activity, view.badge] as [NSView]).filter { !$0.isHidden && $0.frame.width > 0 }
            #expect(!marks.isEmpty, "\(state.name): no mark")
            for mark in marks {
                #expect(mark.frame.minX > view.title.frame.minX, "\(state.name): \(mark) left of the title")
                #expect(mark.frame.midX > view.bounds.midX, "\(state.name): \(mark.frame) not at the row's end")
            }
        }
        // A text-only row's title starts on the leading inset, as before: one x for every state.
        #expect(titleXs.count == 1)
        #expect(titleXs.first == SidebarStyle.workspaceTitleX(icon: nil, treeDepth: 0) + WorkspaceRowView.labelInset)
    }
}
