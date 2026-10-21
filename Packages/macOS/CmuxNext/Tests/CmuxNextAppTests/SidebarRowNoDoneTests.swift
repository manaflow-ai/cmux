import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21, on rows that said "Done" beside a blue dot again: "WHO BROUGHT BACK THE DONE AND
/// THE TIMERS" (#23390 brought the Done back). A workspace row never says Done: a finished, unread
/// chat keeps only its quiet unread dot. What asks for the user (needs you, failed) still reads.
@MainActor @Suite(.serialized)
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
        #expect(view.chip == nil)
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

    @Test func needsYouStillReadsOnTheRow() {
        let (view, window) = row(workspace(.needsYou))
        #expect(shownText(view).contains(SidebarPriorityRowView.chipText(.needsYou, now: Date())))
        window.close()
    }
}
