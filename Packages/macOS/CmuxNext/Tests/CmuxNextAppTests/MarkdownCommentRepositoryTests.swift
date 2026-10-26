@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

private enum ThreadProbe {
    nonisolated static func isMain() -> Bool { Thread.isMainThread }
}

/// Comment persistence must keep the page responsive while preserving the order and durability
/// contract of the existing attribute/fallback store.
@MainActor @Suite(.serialized) struct MarkdownCommentRepositoryTests {
    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) {}
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }

    private actor RecordingStorage: MarkdownTableWidthStoring {
        var value: Data?
        var writes: [Data?] = []
        var writeOnMainActor: [Bool] = []

        func read(_ path: String) async -> Data? { value }

        func write(_ path: String, _ value: Data?) async -> MarkdownTableWidthWrite {
            writes.append(value)
            writeOnMainActor.append(ThreadProbe.isMain())
            self.value = value
            return MarkdownTableWidthWrite(attribute: true, fallback: true)
        }
    }

    private actor DelayedStorage: MarkdownTableWidthStoring {
        var value: Data?

        func read(_ path: String) async -> Data? {
            for _ in 0..<100 { await Task.yield() }
            return value
        }

        func write(_ path: String, _ value: Data?) async -> MarkdownTableWidthWrite {
            for _ in 0..<100 { await Task.yield() }
            self.value = value
            return MarkdownTableWidthWrite(attribute: true, fallback: true)
        }
    }

    private static func quote(_ line: Int, comment: String = "Why?") -> ChatQuote {
        ChatQuote(source: "/repo/README.md", kind: .markdown, lines: line...(line + 1),
                  quoted: "text \(line)", comment: comment)
    }

    @Test func mutationsStayOffTheMainActorAndPreserveOrder() async throws {
        let storage = RecordingStorage()
        let repository = MarkdownCommentRepository(storage: storage)

        let first = try #require(await repository.add(Self.quote(1), id: "first", at: "/repo/README.md"))
        let second = try #require(await repository.add(Self.quote(3), id: "second", at: "/repo/README.md"))
        let removed = try #require(await repository.remove("first", at: "/repo/README.md"))

        #expect(first.written == MarkdownTableWidthWrite(attribute: true, fallback: true))
        #expect(second.written == MarkdownTableWidthWrite(attribute: true, fallback: true))
        #expect(removed.written == MarkdownTableWidthWrite(attribute: true, fallback: true))
        let sequences: [Int] = [first.sequence, second.sequence, removed.sequence]
        #expect(sequences == [1, 2, 3])
        #expect(await storage.writeOnMainActor == [false, false, false])

        let writes = await storage.writes
        let firstData = try #require(writes[0])
        let secondData = try #require(writes[1])
        let finalData = try #require(writes[2])
        let firstList = try #require(ViewerCommentList(data: firstData))
        let secondList = try #require(ViewerCommentList(data: secondData))
        let finalList = try #require(ViewerCommentList(data: finalData))
        #expect(firstList.comments.map(\.id) == ["first"])
        #expect(secondList.comments.map(\.id) == ["first", "second"])
        #expect(finalList.comments.map(\.id) == ["second"])
        #expect(await storage.value == finalData)
    }

    @Test func concurrentAddsDoNotLoseEitherCommentAcrossStorageAwaits() async throws {
        let storage = DelayedStorage()
        let repository = MarkdownCommentRepository(storage: storage)
        async let first = repository.add(Self.quote(1), id: "first", at: "/repo/README.md")
        async let second = repository.add(Self.quote(3), id: "second", at: "/repo/README.md")
        let firstResult = try #require(await first)
        let secondResult = try #require(await second)
        #expect(firstResult.written == MarkdownTableWidthWrite(attribute: true, fallback: true))
        #expect(secondResult.written == MarkdownTableWidthWrite(attribute: true, fallback: true))
        #expect(Set([firstResult.sequence, secondResult.sequence]) == Set([1, 2]))

        let finalData = try #require(await storage.value)
        let finalList = try #require(ViewerCommentList(data: finalData))
        #expect(finalList.comments.map(\.id).sorted() == ["first", "second"])
    }

    @Test func concurrentPageAddsPublishTheNewestListLast() async throws {
        let storage = DelayedStorage()
        let repository = MarkdownCommentRepository(storage: storage)
        let provider = FilePageProvider(kind: .markdown, file: URL(fileURLWithPath: "/repo/README.md"), host: Host(),
                                        libraries: nil, images: NoImages(), comments: repository)
        defer { provider.close() }
        var published: [ViewerCommentList] = []
        provider.onCommentsChanged = { value in
            if let data = value.compactText.data(using: .utf8), let list = ViewerCommentList(data: data) {
                published.append(list)
            }
        }

        async let first = provider.addComment(Self.quote(1), id: "first")
        async let second = provider.addComment(Self.quote(3), id: "second")
        #expect(await first)
        #expect(await second)
        let final = try #require(published.last)
        #expect(final.comments.map(\.id).sorted() == ["first", "second"])
    }

    /// Fixed transcript-size harness used for the before/after receipt. The work is intentionally
    /// the same 100-comment sequence on every run; only the persistence boundary changes.
    @Test func fixedTranscriptPersistenceMetric() async throws {
        let storage = RecordingStorage()
        let repository = MarkdownCommentRepository(storage: storage)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            for index in 0..<100 {
                _ = await repository.add(Self.quote(index + 1), id: "comment-\(index)", at: "/repo/README.md")
            }
        }
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        print("DIFF-COMMENTS fixed-transcript=100 persistence-ms=\(milliseconds)")
        #expect(await storage.writes.count == 100)
    }
}
