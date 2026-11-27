import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A progress tick (OSC 7501 `progress=`, 4 a second per ticking terminal) configures its row's badge; what the badge
/// says to VoiceOver is built when accessibility reads it, not on each tick (sidebar.400.ticking.main_ms_per_s: the
/// summary's "N% done", a number formatter under row configure, ran on every tick of 15 rows while nothing read it).
/// It still says the latest progress when it is read.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowBadgeHelpOnDemandTests {
    /// One tick: the row works at `percent` with three unread.
    private static func tick(_ view: WorkspaceRowView, percent: Int, style: SidebarRowBadgeStyle) {
        var ws = SidebarWorkspace(id: WorkspaceID("tick"), title: "Ticker")
        ws.unread = .count(3)
        ws.activity = .working(progress: Double(percent) / 100)
        var content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        content.activity = ws.activity
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        view.configure(ws, row: row, badgeStyle: style)
    }

    @Test(arguments: [SidebarRowBadgeStyle.corner, .stack])
    func ticksBuildNoBadgeWordsAndAReadSaysTheLatestProgress(style: SidebarRowBadgeStyle) throws {
        let view = WorkspaceRowView(key: .workspace(WorkspaceID("tick")))
        for percent in stride(from: 5, through: 95, by: 5) { Self.tick(view, percent: percent, style: style) }
        let badge = view.rowBadge
        #expect(badge.spokenHelpBuilds == 0, "19 progress ticks built the badge's words \(badge.spokenHelpBuilds) times")
        let help = try #require(badge.accessibilityHelp())
        #expect(help.contains("95"), "the badge does not say the last tick's progress: \(help)")
        #expect(help.contains(Strings.unreadCount(3)), "\(help)")
        #expect(badge.spokenHelpBuilds == 1)
        // An assistive app that reads again before the next tick gets the same words without a build.
        for _ in 0..<10 { _ = badge.accessibilityHelp() }
        #expect(badge.spokenHelpBuilds == 1, "10 reads between ticks built the words \(badge.spokenHelpBuilds - 1) more times")
        // A configure that changes nothing the badge says keeps them.
        Self.tick(view, percent: 95, style: style)
        #expect(badge.accessibilityHelp() == help)
        #expect(badge.spokenHelpBuilds == 1)
        // The next tick drops them; the read after it says the new progress.
        Self.tick(view, percent: 50, style: style)
        let next = try #require(badge.accessibilityHelp())
        #expect(next.contains("50"), "the badge after a new tick does not say its progress: \(next)")
        #expect(badge.spokenHelpBuilds == 2)
    }

    /// The trailing style draws no badge: it says nothing, not the last words a badge style left.
    @Test func aRowThatDrawsNoBadgeSaysNothing() {
        let view = WorkspaceRowView(key: .workspace(WorkspaceID("tick")))
        Self.tick(view, percent: 40, style: .stack)
        #expect(view.rowBadge.accessibilityHelp() != nil)
        Self.tick(view, percent: 45, style: .trailing)
        #expect(view.rowBadge.accessibilityHelp() == nil)
    }
}
