import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct AgentFeedRowModelCacheTests {
    @Test @MainActor func projectionPublishesTheLatestSnapshot() async {
        let originalItems = (0..<40).map { makeItem(id: "row-\($0)") }
        let projection = AgentFeedProjection(items: originalItems)
        #expect(projection.rows.count == originalItems.count)

        let inserted = makeItem(id: "new-row")
        projection.update(items: [inserted] + originalItems)
        await projection.waitForPendingRebuild()

        #expect(projection.rows.first?.id == inserted.id)
        #expect(projection.rows.count == originalItems.count + 1)
    }

    @Test @MainActor func projectionHidesRetainedRowsUntilScopeRefreshCompletes() async {
        let originalItems = (0..<40).map { makeItem(id: "row-\($0)") }
        let initialRevision = AgentFeedItemsRevision(
            sourceRevision: 1,
            scopeRevision: AgentFeedScopeRevision(selection: .all, selectedMachineIDs: nil)
        )
        let nextRevision = AgentFeedItemsRevision(
            sourceRevision: 1,
            scopeRevision: AgentFeedScopeRevision(
                selection: .machine("mac-b"),
                selectedMachineIDs: ["mac-b"]
            )
        )
        let projection = AgentFeedProjection(
            items: originalItems,
            itemsRevision: initialRevision
        )

        projection.update(items: originalItems, itemsRevision: nextRevision)

        #expect(projection.rows(for: nextRevision).isEmpty)
        await projection.waitForPendingRebuild()
        #expect(projection.rows(for: nextRevision).count == originalItems.count)
    }

    @Test @MainActor func projectionKeepsRowsVisibleDuringContentRefresh() async {
        let originalItems = (0..<40).map { makeItem(id: "row-\($0)") }
        let initialRevision = AgentFeedItemsRevision(
            sourceRevision: 1,
            scopeRevision: AgentFeedScopeRevision(selection: .all, selectedMachineIDs: nil)
        )
        let nextRevision = AgentFeedItemsRevision(
            sourceRevision: 2,
            scopeRevision: initialRevision.scopeRevision
        )
        let projection = AgentFeedProjection(
            items: originalItems,
            itemsRevision: initialRevision
        )
        let inserted = makeItem(id: "new-row")

        projection.update(items: [inserted] + originalItems, itemsRevision: nextRevision)

        #expect(projection.rows(for: nextRevision).count == originalItems.count)
        await projection.waitForPendingRebuild()
        #expect(projection.rows(for: nextRevision).first?.id == inserted.id)
    }

    @Test func reusesUnchangedRowsAndRebuildsOnlyChangedRows() {
        let originalItems = (0..<120).map { makeItem(id: "row-\($0)") }
        var cache = AgentFeedRowModelCache()

        let originalModels = cache.update(items: originalItems)
        #expect(cache.lastRebuiltCount == originalItems.count)

        let newItems = [makeItem(id: "new-row")] + originalItems
        let updatedModels = cache.update(items: newItems)
        #expect(cache.lastRebuiltCount == 1)
        #expect(Array(updatedModels.dropFirst()) == originalModels)

        let changedItems = newItems.map { item in
            item.itemID == "row-42" ? item.updating(userReply: "keep going") : item
        }
        _ = cache.update(items: changedItems)
        #expect(cache.lastRebuiltCount == 1)
    }

    private func makeItem(id: String) -> MobileAgentFeedItem {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        return MobileAgentFeedItem(
            macDeviceID: "mac-a",
            macDisplayName: "Mac",
            itemID: id,
            workstreamID: "codex-\(id)",
            source: "codex",
            kind: .stop,
            status: .telemetry,
            createdAt: date,
            updatedAt: date,
            stopReason: "Stopped.",
            fullTextPreview: "Stopped.",
            connectionStatus: .connected
        )
    }
}
