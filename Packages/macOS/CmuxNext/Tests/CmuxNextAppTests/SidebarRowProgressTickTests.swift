import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A working agent's progress tick (OSC 7501 `progress=`, 4 a second per row) changed only the bar's value, yet
/// each one ran the row's whole configure and relaid out and committed every layer of the row
/// (`sidebar.400.ticking.main_ms_per_s`: Core Animation commit about 27% of the ticking main thread). A tick that
/// changes only the value now sets the fill's width; anything else still configures the row.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowProgressTickTests {
    private func row(_ ws: SidebarWorkspace, progress: Double, title: String? = nil) -> SidebarRow {
        var content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        content.progress = SidebarProgress(value: progress)
        return SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                          parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                          content: content)
    }

    private func laidOutRow(_ ws: SidebarWorkspace) -> WorkspaceRowView {
        let view = WorkspaceRowView(key: .workspace(ws.id))
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        view.configure(ws, row: row(ws, progress: 0.1), badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func aValueTickSetsTheFillWithoutConfiguringTheRow() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("tick"), title: "Ticker", lastActivity: Date(timeIntervalSince1970: 0))
        let view = laidOutRow(ws)
        try #require(!view.progressTrack.isHidden && view.progressTrack.bounds.width > 0, "the bar did not lay out")
        let track = view.progressTrack.bounds.width
        for percent in stride(from: 20, through: 90, by: 10) {
            view.configure(ws, row: row(ws, progress: Double(percent) / 100), badgeStyle: .corner)
            #expect(!view.needsLayout, "a value tick asked to lay out the whole row again")
        }
        #expect(view.progressOnlyUpdates == 8, "only \(view.progressOnlyUpdates) of 8 value ticks took the fill-only path")
        #expect(abs(view.progressFill.frame.width - track * 0.9) < 0.5, "the fill is \(view.progressFill.frame.width), not 90% of \(track)")
        // What VoiceOver reads still says the latest value.
        let label = try #require(view.accessibilityLabel())
        #expect(label.contains("90"), "the label does not say the last tick's progress: \(label)")
    }

    /// A tick that also changes something else (here the title) configures the whole row, as before.
    @Test func aTickThatChangesMoreConfiguresTheRow() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("tick2"), title: "Ticker", lastActivity: Date(timeIntervalSince1970: 0))
        let view = laidOutRow(ws)
        var renamed = ws
        renamed.title = "Renamed"
        view.configure(renamed, row: row(renamed, progress: 0.4), badgeStyle: .corner)
        #expect(view.progressOnlyUpdates == 0, "a tick with a new title took the fill-only path")
        #expect(view.needsLayout, "a tick with a new title did not lay the row out")
    }
}
