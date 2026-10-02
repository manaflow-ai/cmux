import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery eager pager")
struct ChatArtifactGalleryEagerPagerTests {
    @Test("fetches cursors sequentially until exhausted")
    func fetchesUntilExhausted() async throws {
        let script = ChatArtifactGalleryPageScript(pages: [
            "cursor-1": page(paths: ["/two"], nextCursor: "cursor-2"),
            "cursor-2": page(paths: ["/three"], nextCursor: nil),
        ])
        let initial = snapshot(paths: ["/one"], nextCursor: "cursor-1", total: 3)

        let result = try await ChatArtifactGalleryEagerPager().loadRemaining(from: initial) { cursor in
            try await script.fetch(cursor: cursor)
        }

        #expect(result.snapshot.referenced.map { $0.path } == ["/one", "/two", "/three"])
        #expect(result.snapshot.nextCursor == nil)
        #expect(!result.reachedSafetyCap)
        #expect(await script.requestedCursors() == ["cursor-1", "cursor-2"])
    }

    @Test("stops at the safety cap and retains the next cursor")
    func respectsSafetyCap() async throws {
        let script = ChatArtifactGalleryPageScript(pages: [
            "cursor-1": page(paths: ["/two", "/three"], nextCursor: "cursor-2"),
            "cursor-2": page(paths: ["/four"], nextCursor: nil),
        ])
        let initial = snapshot(paths: ["/one"], nextCursor: "cursor-1", total: 4)

        let result = try await ChatArtifactGalleryEagerPager(
            maximumReferencedRows: 3
        ).loadRemaining(from: initial) { cursor in
            try await script.fetch(cursor: cursor)
        }

        #expect(result.snapshot.referenced.map { $0.path } == ["/one", "/two", "/three"])
        #expect(result.snapshot.nextCursor == "cursor-2")
        #expect(result.reachedSafetyCap)
        #expect(await script.requestedCursors() == ["cursor-1"])
    }

    @Test("caps an oversized final page even when its cursor is exhausted")
    func capsOversizedFinalPage() async throws {
        let script = ChatArtifactGalleryPageScript(pages: [
            "cursor-1": page(paths: ["/two", "/three"], nextCursor: nil),
        ])
        let initial = snapshot(paths: ["/one"], nextCursor: "cursor-1", total: 3)

        let result = try await ChatArtifactGalleryEagerPager(
            maximumReferencedRows: 2
        ).loadRemaining(from: initial) { cursor in
            try await script.fetch(cursor: cursor)
        }

        #expect(result.snapshot.referenced.map { $0.path } == ["/one", "/two"])
        #expect(result.snapshot.nextCursor == nil)
        #expect(result.reachedSafetyCap)
    }

    @Test("stops before requesting a repeated cursor")
    func stopsAtRepeatedCursor() async throws {
        let script = ChatArtifactGalleryPageScript(pages: [
            "cursor-1": page(paths: ["/two"], nextCursor: "cursor-1"),
        ])
        let initial = snapshot(paths: ["/one"], nextCursor: "cursor-1", total: 3)

        let result = try await ChatArtifactGalleryEagerPager().loadRemaining(from: initial) { cursor in
            try await script.fetch(cursor: cursor)
        }

        #expect(result.snapshot.referenced.map(\.path) == ["/one", "/two"])
        #expect(result.snapshot.nextCursor == "cursor-1")
        #expect(!result.reachedSafetyCap)
        #expect(await script.requestedCursors() == ["cursor-1"])
    }

    @Test("surfaces a stale-generation restart without changing accumulated rows")
    func staleGenerationRestart() async throws {
        let initial = snapshot(paths: ["/one"], nextCursor: "cursor-1", total: 3)

        let result = try await ChatArtifactGalleryEagerPager().loadRemaining(from: initial) { _ in
            ChatArtifactGalleryPage(
                sessionID: "session",
                generation: "new",
                requiresPagingRestart: true
            )
        }

        #expect(result.requiresPagingRestart)
        #expect(!result.reachedSafetyCap)
        #expect(result.snapshot == initial)
    }

    private func snapshot(
        paths: [String],
        nextCursor: String?,
        total: Int
    ) -> ChatArtifactGallerySnapshot {
        ChatArtifactGallerySnapshot(page: ChatArtifactGalleryPage(
            sessionID: "session",
            referenced: paths.map(item),
            referencedTotal: total,
            nextCursor: nextCursor,
            generation: "generation"
        ))
    }

    private func page(
        paths: [String],
        nextCursor: String?
    ) -> ChatArtifactGalleryPage {
        ChatArtifactGalleryPage(
            sessionID: "session",
            referenced: paths.map(item),
            referencedTotal: paths.count,
            nextCursor: nextCursor,
            generation: "generation"
        )
    }

    private func item(path: String) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: .text,
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
    }
}
