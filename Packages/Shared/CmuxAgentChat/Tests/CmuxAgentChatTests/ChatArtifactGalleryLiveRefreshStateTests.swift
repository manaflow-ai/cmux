import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery live refresh")
struct ChatArtifactGalleryLiveRefreshStateTests {
    @Test("a top or fitting gallery merges fresh rows immediately")
    func mergesAtTop() throws {
        var state = ChatArtifactGalleryLiveRefreshState()
        let displayed = snapshot(generation: "one", paths: ["/old.txt"])
        let fresh = snapshot(generation: "two", paths: ["/new.txt", "/old.txt"])

        let received = state.receive(
            fresh: fresh,
            displayed: displayed,
            isAtTopOrFits: true
        )
        let merged = try #require(received)

        #expect(merged.referenced.map(\.path) == ["/new.txt", "/old.txt"])
        #expect(state.pendingNewFileCount == 0)
    }

    @Test("a reading position keeps the visible snapshot and reports unseen paths")
    func defersAwayFromTop() {
        var state = ChatArtifactGalleryLiveRefreshState()
        let displayed = snapshot(generation: "one", paths: ["/old.txt"])
        let fresh = snapshot(generation: "two", paths: ["/new-a.txt", "/new-b.txt", "/old.txt"])

        let merged = state.receive(
            fresh: fresh,
            displayed: displayed,
            isAtTopOrFits: false
        )

        #expect(merged == nil)
        #expect(state.pendingNewFileCount == 2)
        #expect(displayed.referenced.map(\.path) == ["/old.txt"])
    }

    @Test("applying a pending refresh clears the pill and preserves loaded history")
    func appliesPendingRefresh() throws {
        var state = ChatArtifactGalleryLiveRefreshState()
        let displayed = snapshot(generation: "one", paths: ["/old.txt", "/older.txt"])
        let fresh = snapshot(generation: "two", paths: ["/new.txt", "/old.txt"])
        #expect(state.receive(
            fresh: fresh,
            displayed: displayed,
            isAtTopOrFits: false
        ) == nil)

        let pendingApplication = state.applyPending(to: displayed)
        let applied = try #require(pendingApplication)

        #expect(applied.referenced.map(\.path) == ["/new.txt", "/old.txt", "/older.txt"])
        #expect(applied.referencedTotal == 3)
        #expect(applied.generation == "two")
        #expect(state.pendingNewFileCount == 0)
        #expect(state.applyPending(to: applied) == nil)
    }

    private func snapshot(generation: String, paths: [String]) -> ChatArtifactGallerySnapshot {
        ChatArtifactGallerySnapshot(page: ChatArtifactGalleryPage(
            sessionID: "session",
            referenced: paths.map { path in
                ChatArtifactGalleryItem(
                    path: path,
                    kind: .text,
                    displayName: URL(fileURLWithPath: path).lastPathComponent,
                    provenance: .referenced
                )
            },
            referencedTotal: paths.count,
            generation: generation
        ))
    }
}
