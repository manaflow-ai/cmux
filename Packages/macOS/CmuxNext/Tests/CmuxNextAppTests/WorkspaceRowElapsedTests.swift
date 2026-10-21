import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A working row shows how long the agent has worked ("4m", Leo 2026-10-20) beside its dot when
/// the name keeps its full width; a narrow row stays as it was.
@MainActor @Suite(.serialized)
struct WorkspaceRowElapsedTests {
    private func working(_ title: String, since: Date?) -> SidebarWorkspace {
        // An agent's last update gives the row an age, which the running time replaces.
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: title, lastActivity: Date(), agentWorking: true,
                                  activity: .working(progress: nil))
        ws.detail.activitySince = since
        return ws
    }

    /// The row as the list shows it, `width` wide, in a window so its minute tick may arm.
    private func row(_ ws: SidebarWorkspace, width: CGFloat) -> (WorkspaceRowView, NSWindow) {
        let content = WorkspaceRowContent(ws, preferences: .defaults)
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
        view.configure(ws, row: row, badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @Test func theRunningTimeReadsInWholeMinutes() {
        let now = Date()
        #expect(WorkspaceRowContent.workingElapsed(since: now.addingTimeInterval(-59), now: now) == nil)
        #expect(WorkspaceRowContent.workingElapsed(since: now.addingTimeInterval(-4 * 60 - 30), now: now) == "4m")
        #expect(WorkspaceRowContent.workingElapsed(since: now.addingTimeInterval(-63 * 60), now: now) == "1h 3m")
    }

    @Test func onlyAWorkingRowCarriesItsStart() {
        let since = Date().addingTimeInterval(-300)
        #expect(WorkspaceRowContent(working("Fix the build", since: since), preferences: .defaults).workingSince == since)
        var idle = working("Fix the build", since: since)
        (idle.agentWorking, idle.activity) = (false, .idle)
        #expect(WorkspaceRowContent(idle, preferences: .defaults).workingSince == nil)
    }

    @Test func aWideRowShowsTheTimeBesideTheDot() {
        let (view, window) = row(working("Fix the build", since: Date().addingTimeInterval(-4 * 60 - 30)), width: 320)
        #expect(!view.elapsedLabel.isHidden)
        #expect(view.elapsedLabel.stringValue == "4m")
        // Between the whole name and the trailing marks.
        #expect(view.title.frame.maxX <= view.elapsedLabel.frame.minX)
        #expect(view.title.frame.width >= view.title.intrinsicContentSize.width)
        #expect(view.elapsedLabel.frame.maxX <= view.rowBadge.frame.minX)
        #expect(view.timeLabel.isHidden)
        window.close()
    }

    /// A row parked in the pool and taken back for its own workspace keeps its content, and its time.
    @Test func aRowBackFromThePoolKeepsItsTime() {
        let ws = working("Fix the build", since: Date().addingTimeInterval(-4 * 60 - 30))
        let (view, window) = row(ws, width: 320)
        view.prepareForReuse(key: .workspace(ws.id))
        let content = WorkspaceRowContent(ws, preferences: .defaults)
        view.configure(ws, row: SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                                           parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0,
                                           groupColor: nil, content: content), badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        #expect(!view.elapsedLabel.isHidden)
        #expect(view.elapsedLabel.stringValue == "4m")
        window.close()
    }

    @Test func aNarrowRowKeepsItsName() {
        let (view, window) = row(working("Redesign the source control pane's commit flow", since: Date().addingTimeInterval(-600)),
                                 width: 200)
        #expect(view.elapsedLabel.isHidden)
        window.close()
    }

    @Test func underAMinuteShowsNothing() {
        let (view, window) = row(working("Fix the build", since: Date().addingTimeInterval(-10)), width: 320)
        #expect(view.elapsedLabel.isHidden)
        #expect(view.timeLabel.isHidden)
        window.close()
    }

    /// A quiet row keeps the age of its last change.
    @Test func anIdleRowKeepsItsAge() {
        var idle = working("Fix the build", since: nil)
        (idle.agentWorking, idle.activity) = (false, .idle)
        let (view, window) = row(idle, width: 320)
        #expect(view.elapsedLabel.isHidden)
        #expect(!view.timeLabel.isHidden)
        window.close()
    }
}
