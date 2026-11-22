import AppKit
@testable import CmuxNextDesign
import CmuxNextResources
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-22: "i have this layout. so. the preview should be able to depict that." and "fit symbols properly in
/// the initial preview without doing stupid layout shifts now or later". A split workspace's hover card draws its
/// panes side by side with each tab's CPU and memory inline, and the first sample (no CPU yet) and a later one lay
/// out at the same size.
@MainActor @Suite(.serialized) struct WorkspaceLayoutPreviewTests {
    @Test func threeColumnsDrawAsThreeTilesLeftToRight() throws {
        let card = WorkspaceHoverCardGallery.splitPreviewCard(.numbers, sampled: false)
        #expect(card.showsLayoutPreview)
        let tiles = card.layoutPreview.subviews.sorted { $0.frame.minX < $1.frame.minX }
        #expect(tiles.count == 3)
        // Side by side: same top, no overlap, chat pane widest (ratio 0.42 of the row against 0.29 each).
        #expect(Set(tiles.map(\.frame.minY)).count == 1)
        for (a, b) in zip(tiles, tiles.dropFirst()) { #expect(a.frame.maxX <= b.frame.minX) }
        #expect(tiles[0].frame.width > tiles[1].frame.width)
    }

    @Test func samplesArrivingNeverMoveTheCard() throws {
        for style in [WorkspaceLayoutPreviewView.StatsStyle.numbers, .symbols, .memoryFirst] {
            let card = WorkspaceHoverCardGallery.splitPreviewCard(style, sampled: false)
            card.layoutSubtreeIfNeeded()
            let before = card.fittingSize
            let frames = card.layoutPreview.subviews.map(\.frame)
            let first = card.layoutPreview.reportedLines
            card.setResources(WorkspaceHoverCardGallery.splitReport(sampled: true))
            card.layoutSubtreeIfNeeded()
            #expect(card.fittingSize == before, "\(style)")
            #expect(card.layoutPreview.subviews.map(\.frame) == frames, "\(style)")
            #expect(card.layoutPreview.reportedLines != first, "\(style)")
        }
    }

    @Test func firstSampleHoldsCpuRoomWithADash() throws {
        let card = WorkspaceHoverCardGallery.splitPreviewCard(.numbers, sampled: false)
        let lines = card.layoutPreview.reportedLines
        #expect(lines.contains { $0.hasPrefix("npm run dev") && $0.contains("–") && $0.contains("1.2G") })
        card.setResources(WorkspaceHoverCardGallery.splitReport(sampled: true))
        #expect(card.layoutPreview.reportedLines.contains { $0.hasPrefix("npm run dev") && $0.contains("138%") })
    }

    @Test func onePaneKeepsTheTabList() throws {
        var workspace = SidebarWorkspace(id: WorkspaceID("one"), machineID: .local, title: "one")
        workspace.tabs = Array(WorkspaceHoverCardGallery.splitTabs.prefix(2))
        let card = WorkspaceHoverCardView()
        card.configureTabs(title: workspace.title, tabs: workspace.tabs, now: Date())
        card.configureLayout(SidebarPaneLayout(root: .leaf("p"), panes: [.init(id: "p", tabs: workspace.tabs.map(\.id), active: 0)]),
                             tabs: workspace.tabs)
        #expect(!card.showsLayoutPreview)
        #expect(card.layoutPreview.isHidden)
    }

    @Test func geometryTextFitsItsSlot() {
        #expect(WorkspacePreviewGeometry.cpuText(ResourceUsage(cpu: nil, memoryBytes: 1)) == "–")
        #expect(WorkspacePreviewGeometry.cpuText(ResourceUsage(cpu: 0.004)) == "<1%")
        #expect(WorkspacePreviewGeometry.cpuText(ResourceUsage(cpu: 1.38)) == "138%")
        #expect(WorkspacePreviewGeometry.memoryText(ResourceUsage(memoryBytes: 840 << 20)) == "840M")
        #expect(WorkspacePreviewGeometry.memoryText(ResourceUsage(memoryBytes: 1_270 << 20)) == "1.2G")
        #expect(WorkspacePreviewGeometry.memoryText(ResourceUsage(memoryBytes: 12 << 30)) == "12G")
    }
}
