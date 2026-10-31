import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-10-21, on rows that said "Done" beside a blue dot and "10m" beside the working mark
/// again: "WHO BROUGHT BACK THE DONE AND THE TIMERS" (#23390 brought the Done back, #22826 the
/// timer). A workspace row never says Done and never shows how long its agent has worked: a
/// finished, unread chat keeps only its quiet unread dot, a working one its spinner. What asks for
/// the user (needs you, failed) still reads.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowNoDoneTests {
    private func workspace(_ chip: SidebarPriorityEntry.State?) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "Fix the build", lastActivity: Date())
        ws.agentChip = chip
        ws.unread = .dot
        return ws
    }

    /// The row the list draws for `ws`: its content through the layout (where the chip is read),
    /// configured and laid out in a window.
    private func row(_ ws: SidebarWorkspace) -> (WorkspaceRowView, NSWindow) {
        let content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        let view = WorkspaceRowView(key: row.key)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        view.configure(ws, row: row, badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// Every line of text the row shows, at any depth.
    private func shownText(_ view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            guard !sub.isHidden else { return [] }
            let own = (sub as? any ShownText).map { [$0.stringValue] } ?? []
            return own + shownText(sub)
        }.filter { !$0.isEmpty }
    }

    @Test func aFinishedChatsRowNeverSaysDone() {
        let (view, window) = row(workspace(.done))
        let done = SidebarPriorityRowView.chipText(.done, now: Date())
        #expect(!shownText(view).contains(done), "the row draws \(shownText(view))")
        #expect(view.accessibilityLabel()?.contains(done) != true)
        // The quiet unread dot is the finished chat's only cue.
        #expect(view.accessibilityLabel()?.contains(Strings.unreadDot) == true)
        window.close()
    }

    @Test func onlyWhatAsksForTheUserReachesARow() {
        #expect(WorkspaceRowContent.rowChip(.done) == nil)
        #expect(WorkspaceRowContent.rowChip(.working(since: Date())) == nil)
        #expect(WorkspaceRowContent.rowChip(.idle) == nil)
        for chip: SidebarPriorityEntry.State in [.needsYou, .failed, .lost, .ciFailing] {
            #expect(WorkspaceRowContent.rowChip(chip) == chip)
        }
    }

    @Test func aWorkingRowShowsNoRunningTime() {
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "Fix the build", lastActivity: Date(), agentWorking: true,
                                  activity: .working(progress: nil))
        ws.detail.activitySince = Date().addingTimeInterval(-10 * 60)
        let (view, window) = row(ws)
        // "10m", "1h 3m", "2d": a number and a unit, the running time's shape.
        let timers = shownText(view).filter { $0.range(of: #"^\d+\s?(s|m|h|d|min|hr)\b"#, options: .regularExpression) != nil }
        #expect(timers.isEmpty, "the row draws \(shownText(view))")
        window.close()
    }

    /// No status words at all (Leo 2026-10-21, on a blue dot beside "Needs you": "why ISN'T THIS
    /// JUST A YELLOW DOT!?"): the badge's dot says it; only the accessibility label words it.
    @Test func aRowShowsNoStatusWords() {
        for chip: SidebarPriorityEntry.State in [.needsYou, .failed, .lost, .ciFailing, .done] {
            let (view, window) = row(workspace(chip))
            let word = SidebarPriorityRowView.chipText(chip, now: Date())
            #expect(!shownText(view).contains(word), "\(chip): the row draws \(shownText(view))")
            window.close()
        }
        let (view, window) = row(workspace(.needsYou))
        #expect(view.accessibilityLabel()?.contains(SidebarPriorityRowView.chipText(.needsYou, now: Date())) == true)
        window.close()
    }

    /// A chat asking for the user beside a failed or lost one, or on a row whose own status failed:
    /// the row draws the one yellow dot, never the blue one. The failure used to outrank the
    /// question, and with no "Needs you" word left the row read Ready (codex review of #23767).
    @Test func needsYouBesideAFailureIsTheYellowDot() throws {
        for own: StatusIndicatorState in [.idle, .error] {
            for order in [["failed", "input"], ["input", "lost"]] {
                var ws = workspace(.needsYou)
                ws.activity = own
                let lanes = try order.enumerated().map { index, state in
                    try #require(AgentActivityLane.of(summary: ["sessionId": "s\(index)", "name": "s\(index)", "lane": ["state": state]]))
                }
                SidebarLaneStatus.merge(lanes, into: &ws)
                let (view, window) = row(ws)
                #expect(view.rowBadge.states == [.waiting], "own \(own), lanes \(order): \(view.rowBadge.states)")
                window.close()
            }
        }
    }
}
