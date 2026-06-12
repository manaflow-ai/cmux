import Foundation
import Testing
import CmuxCanvas
@testable import CmuxCanvasUI

@MainActor
@Suite("CanvasModel")
struct CanvasModelTests {
    private func makeModel(gap: Double = 16) -> CanvasModel {
        CanvasModel(metricsProvider: {
            CanvasMetrics(gap: gap, snapThreshold: 8, minPaneSize: CanvasSize(width: 120, height: 80))
        })
    }

    @Test func syncAddsNewPanesAndReportsThem() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        let added = model.syncPanes(panelIds: [a, b], focusedPanelId: nil)
        #expect(Set(added) == Set([a, b]))
        #expect(model.frame(of: a) != nil)
        #expect(model.frame(of: b) != nil)
        // Placed panes never overlap.
        let fa = model.frame(of: a)!
        let fb = model.frame(of: b)!
        #expect(!fa.intersects(fb))
    }

    @Test func syncRemovesDepartedPanes() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.syncPanes(panelIds: [a, b], focusedPanelId: nil)
        let added = model.syncPanes(panelIds: [a], focusedPanelId: a)
        #expect(added.isEmpty)
        #expect(model.frame(of: b) == nil)
        #expect(model.frame(of: a) != nil)
    }

    @Test func seedOnlyFillsPanesWithoutFrames() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.syncPanes(panelIds: [a], focusedPanelId: nil)
        let existing = model.frame(of: a)!
        model.seedFromSplitFrames([
            a: CGRect(x: 999, y: 999, width: 500, height: 500),
            b: CGRect(x: 0, y: 0, width: 400, height: 300),
        ])
        // The existing canvas arrangement is never overwritten.
        #expect(model.frame(of: a) == existing)
        #expect(model.frame(of: b) == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test func restoreFramesReplacesLayoutInZOrder() {
        let model = makeModel()
        let stale = UUID()
        model.syncPanes(panelIds: [stale], focusedPanelId: nil)
        let a = UUID()
        let b = UUID()
        model.restoreFrames([
            (id: a, frame: CGRect(x: 0, y: 0, width: 300, height: 200)),
            (id: b, frame: CGRect(x: 400, y: 0, width: 300, height: 200)),
        ])
        #expect(model.frame(of: stale) == nil)
        #expect(model.layout.paneIDs.map(\.rawValue) == [a, b])
    }

    @Test func bringToFrontReordersPersistablePanes() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.restoreFrames([
            (id: a, frame: CGRect(x: 0, y: 0, width: 300, height: 200)),
            (id: b, frame: CGRect(x: 400, y: 0, width: 300, height: 200)),
        ])
        model.bringToFront(a)
        #expect(model.persistablePanes.map(\.panelId) == [b, a])
    }

    @Test func revisionAdvancesOnMutationOnly() {
        let model = makeModel()
        let a = UUID()
        model.syncPanes(panelIds: [a], focusedPanelId: nil)
        let before = model.revision
        model.syncPanes(panelIds: [a], focusedPanelId: a)
        #expect(model.revision == before)
        model.setFrame(CGRect(x: 5, y: 5, width: 300, height: 200), for: a)
        #expect(model.revision != before)
    }

    @Test func alignmentDefaultsToAllPanes() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.restoreFrames([
            (id: a, frame: CGRect(x: 0, y: 0, width: 300, height: 200)),
            (id: b, frame: CGRect(x: 400, y: 50, width: 300, height: 200)),
        ])
        let changed = model.applyAlignment(.alignTop, to: [], reference: a)
        #expect(changed)
        #expect(model.frame(of: b)?.origin.y == 0)
    }
}
