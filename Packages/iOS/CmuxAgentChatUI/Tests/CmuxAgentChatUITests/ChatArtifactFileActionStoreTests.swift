import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Chat artifact file actions")
struct ChatArtifactFileActionStoreTests {
    @Test("materialized files retain their source name and reuse cached bytes")
    func materializeNamedCachedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-file-action-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        let actionDirectory = root.appendingPathComponent("actions", isDirectory: true)
        let bytes = Data("quarterly results".utf8)
        let modifiedAt = Date(timeIntervalSince1970: 123)
        let source = CountingContentSource(values: ["report": bytes])
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            scope: .chat(sessionID: "session"),
            contentCache: ChatArtifactContentCache(directory: cacheDirectory),
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: Int64(bytes.count),
                    modifiedAt: modifiedAt,
                    kind: .text,
                    mimeType: "text/plain"
                )
            },
            fetch: { _, _ in bytes },
            stream: { _, receive in
                try await source.fetch(key: "report", receive: receive)
            }
        )
        let store = ChatArtifactFileActionStore(directory: actionDirectory)

        let first = try await store.materialize(
            path: "/Users/example/Quarterly Report.txt",
            loader: loader
        )
        let second = try await store.materialize(
            path: "/Users/example/Quarterly Report.txt",
            loader: loader
        )

        #expect(first.lastPathComponent == "Quarterly Report.txt")
        #expect(second.lastPathComponent == "Quarterly Report.txt")
        #expect(try Data(contentsOf: first) == bytes)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(await source.fetchCount(for: "report") == 1)

        await store.remove(first)
        await store.remove(second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }
}
