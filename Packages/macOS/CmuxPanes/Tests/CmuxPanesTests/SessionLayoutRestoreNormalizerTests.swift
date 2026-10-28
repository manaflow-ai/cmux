import Foundation
import Testing
@testable import CmuxPanes

struct SessionLayoutRestoreNormalizerTests {
    @Test func preservesOrdinaryLayoutAndSelection() {
        let ids = [UUID(), UUID(), UUID()]
        let tree = SessionWorkspaceLayoutSnapshot.split(.init(
            orientation: .horizontal, dividerPosition: 0.3,
            first: .pane(.init(panelIds: Array(ids.prefix(2)), selectedPanelId: ids[1], isFullWidthTabMode: true)),
            second: .pane(.init(panelIds: [ids[2]], selectedPanelId: ids[2]))
        ))
        var normalizer = SessionLayoutRestoreNormalizer(maximumNodes: 100, maximumDepth: 10)
        let result = normalizer.normalize(tree, panelIDs: ids)
        #expect(result.layout == tree)
        #expect(result.droppedPanelCount == 0)
    }

    @Test func deduplicatesReferencesAndCollapsesEmptyBranches() {
        let id = UUID()
        let tree = SessionWorkspaceLayoutSnapshot.split(.init(
            orientation: .vertical, dividerPosition: 0.4,
            first: .pane(.init(panelIds: [id, id, UUID()], selectedPanelId: id)),
            second: .pane(.init(panelIds: [id], selectedPanelId: id))
        ))
        var normalizer = SessionLayoutRestoreNormalizer(maximumNodes: 100, maximumDepth: 10)
        let result = normalizer.normalize(tree, panelIDs: [id])
        #expect(result.layout == .pane(.init(panelIds: [id], selectedPanelId: id)))
    }

    @Test func sharesNodeBudgetAcrossContainers() {
        let ids = [UUID(), UUID()]
        let tree = SessionWorkspaceLayoutSnapshot.split(.init(
            orientation: .horizontal, dividerPosition: 0.5,
            first: .pane(.init(panelIds: [ids[0]], selectedPanelId: ids[0])),
            second: .pane(.init(panelIds: [ids[1]], selectedPanelId: ids[1]))
        ))
        var normalizer = SessionLayoutRestoreNormalizer(maximumNodes: 3, maximumDepth: 10)
        #expect(normalizer.normalize(tree, panelIDs: ids).layout == tree)
        #expect(normalizer.normalize(tree, panelIDs: ids).layout == .pane(.init(panelIds: ids, selectedPanelId: ids[0])))
    }

    @Test func depthCapReportsOnlyUnreachablePanels() {
        let kept = UUID(), dropped = UUID()
        let tree = SessionWorkspaceLayoutSnapshot.split(.init(
            orientation: .horizontal, dividerPosition: 0.5,
            first: .pane(.init(panelIds: [kept], selectedPanelId: kept)),
            second: .split(.init(
                orientation: .vertical, dividerPosition: 0.5,
                first: .pane(.init(panelIds: [dropped], selectedPanelId: dropped)),
                second: .pane(.init(panelIds: [], selectedPanelId: nil))
            ))
        ))
        var normalizer = SessionLayoutRestoreNormalizer(maximumNodes: 100, maximumDepth: 2)
        let result = normalizer.normalize(tree, panelIDs: [kept, dropped])
        #expect(result.layout == .pane(.init(panelIds: [kept], selectedPanelId: kept)))
        #expect(result.droppedPanelCount == 1)
    }

    @Test func reportsPanelsAbsentFromAnOtherwiseValidLayout() {
        let kept = UUID(), omitted = UUID()
        let tree = SessionWorkspaceLayoutSnapshot.pane(.init(panelIds: [kept], selectedPanelId: kept))
        var normalizer = SessionLayoutRestoreNormalizer(maximumNodes: 100, maximumDepth: 10)
        let result = normalizer.normalize(tree, panelIDs: [kept, omitted])
        #expect(result.layout == tree)
        #expect(result.droppedPanelCount == 1)
    }

    @Test func maximumSkewedLayoutNormalizesWithoutRecursiveTraversal() {
        let ids = (0..<512).map { _ in UUID() }
        var tree = SessionWorkspaceLayoutSnapshot.pane(.init(panelIds: [ids[0]], selectedPanelId: ids[0]))
        for id in ids.dropFirst() {
            tree = .split(.init(
                orientation: .horizontal, dividerPosition: 0.5,
                first: tree,
                second: .pane(.init(panelIds: [id], selectedPanelId: id))
            ))
        }
        var normalizer = SessionLayoutRestoreNormalizer(maximumNodes: 16_384, maximumDepth: 512)
        let start = ContinuousClock.now
        let result = normalizer.normalize(tree, panelIDs: ids)
        let elapsed = start.duration(to: .now)
        #expect(result.layout == tree)
        #expect(result.droppedPanelCount == 0)
        print("512-panel skewed restore normalization: \(elapsed)")
    }
}
