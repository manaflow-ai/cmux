import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/48363: hovering a workspace row drew its close (✕) on top of the
/// row's pull request badge (the red failing glyph), the blue unread dot and the red error mark. Every trailing
/// indicator either gives way to the ✕ (fades out while it shows) or sits beside it; none may stay drawn under it.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowCloseClearsMarksTests {
    static let row = WorkspaceID("cc-row"), other = WorkspaceID("cc-other")

    enum Marks: String, CaseIterable, CustomTestStringConvertible {
        case pullRequest, pullRequestUnread, pullRequestError, pullRequestCount, unreadDot, unreadCount, error, hookText,
             everything

        var testDescription: String { rawValue }

        var workspace: SidebarWorkspace {
            let unread: UnreadState = switch self {
            case .pullRequestUnread, .unreadDot, .everything: .dot
            case .pullRequestCount, .unreadCount: .count(3)
            default: .none
            }
            let activity: StatusIndicatorState = switch self {
            case .pullRequestError, .error, .everything: .error
            default: .idle
            }
            let hook = self == .hookText || self == .everything ? "#48363 checks failing" : nil
            return SidebarWorkspace(id: SidebarRowCloseClearsMarksTests.row, title: "Sidebar close overlap fix",
                                    pullRequest: hook, unread: unread, activity: activity)
        }

        var pullRequests: Bool { rawValue.hasPrefix("pullRequest") || self == .everything }
    }

    static func sidebar(_ marks: Marks, style: SidebarRowBadgeStyle) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: other, title: "Release notes")), .workspace(marks.workspace),
        ])], activeWorkspaceID: other)
        model.rowBadgeStyle = style
        let design = DesignSettings()
        design.sidebarSections.workspaceRow.base.shown.insert(.pullRequest)
        let sidebar = SidebarView(model: model, design: design)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// Every drawn indicator of `row` whose frame meets `rect` (row coordinates), by name.
    static func drawn(in row: WorkspaceRowView, meeting rect: NSRect) -> [String] {
        let marks: [(String, NSView?)] = [
            ("pullRequests", row.pullRequests), ("prText", row.prBadge), ("unread", row.badge), ("rowBadge", row.rowBadge),
            ("activity", row.activity), ("agentMark", row.agentMark), ("muted", row.mutedMark), ("cloud", row.cloudMark),
            ("usageWarning", row.usageWarningMark), ("tabCount", row.tabCount), ("keycap", row.keycap), ("rollUp", row.rollUp),
            ("time", row.timeLabel), ("presence", row.presenceDots), ("drive", row.driveIndicator),
            ("treeFold", row.treeFoldSlot.made), ("audio", row.audioSlot.made),
        ]
        return marks.compactMap { name, view in
            guard let view, !view.isHidden, view.frame.width > 0,
                  SidebarTrailingColumnTests.drawnAlpha(view, below: row) > 0.01 else { return nil }
            let frame = row.convert(view.bounds, from: view).insetBy(dx: 0.5, dy: 0.5)
            return frame.intersects(rect) ? "\(name) at \(frame.minX)...\(frame.maxX)" : nil
        }
    }

    @Test(arguments: Marks.allCases, SidebarRowBadgeStyle.allCases)
    func theHoverCloseCoversNoIndicator(_ marks: Marks, _ style: SidebarRowBadgeStyle) throws {
        SidebarSessionTree.shared.pullRequests = marks.pullRequests
            ? [Self.row: SidebarPullRequestBadge(count: marks == .everything ? 2 : 1, status: .failing, items: [
                SidebarPullRequestItem(url: "https://github.com/o/r/pull/1", repository: "o/r", number: 1, title: "PR 1", state: .failing),
            ])] : [:]
        defer { SidebarSessionTree.shared.pullRequests = [:] }
        for spot in SidebarRowCloseSpot.allCases {
            try SidebarRowCloseSpotTests.withCloseSpot(spot) {
                let (sidebar, window) = Self.sidebar(marks, style: style)
                defer { window.close() }
                window.orderFrontRegardless()
                sidebar.renderNow()
                let row = try #require(sidebar.list.rowViews[.workspace(Self.row)] as? WorkspaceRowView)
                row.layoutSubtreeIfNeeded()
                if marks.pullRequests { try #require(!row.pullRequests.isHidden, "the row draws no pull request badge") }
                row.isHovered = true
                row.layoutSubtreeIfNeeded()
                let close = row.closeButton
                try #require(!close.isHidden && close.alphaValue > 0, "\(spot): no ✕ on the hovered row")
                let more = row.moreButton
                for (control, rect) in [("✕", close.frame), ("⋮", more.isHidden || more.alphaValue == 0 ? nil : more.frame)] {
                    guard let rect else { continue }
                    let under = Self.drawn(in: row, meeting: rect)
                    #expect(under.isEmpty, "\(spot), \(style), \(marks): the \(control) at \(rect.minX)...\(rect.maxX) covers \(under)")
                }
                // A badge that gave way opens no pull request card from under the ✕.
                let badge = row.pullRequests
                if marks.pullRequests, badge.alphaValue == 0 {
                    let onScreen = window.convertToScreen(badge.convert(badge.bounds, to: nil))
                    let center = CGPoint(x: onScreen.midX, y: onScreen.midY)
                    #expect(!WorkspaceHoverCardController.onPullRequestBadge(badge, window: window, screenPoint: center),
                            "\(spot): the hidden badge still takes the pointer")
                    #expect(badge.pointedItems == nil)
                }
                row.isHovered = false
                row.layoutSubtreeIfNeeded()
                if marks.pullRequests {
                    #expect(!row.pullRequests.isHidden && row.pullRequests.alphaValue > 0, "\(spot): the badge stayed hidden after the hover")
                }
            }
        }
    }
}
