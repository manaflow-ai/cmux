import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct AgentFeedCacheStoreTests {
    @Test func snapshotsAreBoundedScopedAndClearable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agent-feed-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentFeedCacheStore(directory: directory)
        let now = Date()

        for index in 0..<22 {
            await store.upsert(
                AgentFeedCachedSnapshot(
                    ownerKey: "mac-\(index)",
                    macDeviceID: "mac-\(index)",
                    instanceTag: "dev",
                    displayName: "Mac \(index)",
                    responseData: Data("snapshot-\(index)".utf8),
                    cachedAt: now.addingTimeInterval(TimeInterval(index))
                ),
                scopeKey: "user-a\tteam-a"
            )
        }

        let scoped = await store.load(scopeKey: "user-a\tteam-a")
        #expect(scoped.count == 20)
        #expect(scoped.first?.ownerKey == "mac-21")
        #expect(await store.load(scopeKey: "user-b\tteam-a").isEmpty)

        await store.clear(scopeKey: "user-a\tteam-a")
        #expect(await store.load(scopeKey: "user-a\tteam-a").isEmpty)
    }

    @Test @MainActor func diskPayloadRemovesRawToolInput() throws {
        let raw = Data(#"{"revision":1,"items":[{"tool_input":"secret","tool_input_capabilities":"capability","tool_input_summary":"command: …","text":"safe"}]}"#.utf8)

        let sanitized = MobileShellComposite.sanitizedAgentFeedCacheData(raw)
        let root = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let items = try #require(root["items"] as? [[String: Any]])
        let item = try #require(items.first)

        #expect(item["tool_input"] == nil)
        #expect(item["tool_input_capabilities"] == nil)
        #expect(item["tool_input_summary"] as? String == "command: …")
        #expect(item["text"] as? String == "safe")
    }
}
