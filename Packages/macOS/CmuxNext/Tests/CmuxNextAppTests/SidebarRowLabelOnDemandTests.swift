import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A progress tick (OSC 7501 `progress=`, 4 a second per ticking terminal) configures its row; the row's
/// accessibility label is built when accessibility reads it, not on each tick (sidebar.400.ticking.main_ms_per_s:
/// the label's localized numbers, CFNumberFormatterCreate under row configure, ran on every tick of 15 rows while no
/// assistive app listened). The label still says the latest progress when it is read.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowLabelOnDemandTests {
    @Test func ticksBuildNoLabelAndAReadSaysTheLatestProgress() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("tick"), title: "Ticker", lastActivity: Date())
        let view = WorkspaceRowView(key: .workspace(ws.id))
        for percent in stride(from: 5, through: 95, by: 5) {
            var content = SidebarLayoutOptions().rowContent(ws, machine: nil)
            content.progress = SidebarProgress(value: Double(percent) / 100)
            let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                                 parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                                 content: content)
            view.configure(ws, row: row, badgeStyle: .corner)
        }
        #expect(view.spokenLabelBuilds == 0, "19 progress ticks built the row's label \(view.spokenLabelBuilds) times")
        let label = try #require(view.accessibilityLabel())
        #expect(label.contains("Ticker"), "\(label)")
        #expect(label.contains("95"), "the label does not say the last tick's progress: \(label)")
        #expect(view.spokenLabelBuilds == 1)
        // An assistive app that reads again before the next tick gets the same words without a build.
        for _ in 0..<10 { _ = view.accessibilityLabel() }
        #expect(view.spokenLabelBuilds == 1, "10 reads between ticks built the label \(view.spokenLabelBuilds - 1) more times")
        // The next tick drops it; the read after it says the new progress.
        var content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        content.progress = SidebarProgress(value: 0.5)
        view.configure(ws, row: SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                                          parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                                          content: content), badgeStyle: .corner)
        let next = try #require(view.accessibilityLabel())
        #expect(next.contains("50"), "the label after a new tick does not say its progress: \(next)")
        #expect(view.spokenLabelBuilds == 2)
    }
}
