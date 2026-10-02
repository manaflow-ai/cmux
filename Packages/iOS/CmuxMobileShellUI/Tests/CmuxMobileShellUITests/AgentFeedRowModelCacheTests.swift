import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct AgentFeedRowModelCacheTests {
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
