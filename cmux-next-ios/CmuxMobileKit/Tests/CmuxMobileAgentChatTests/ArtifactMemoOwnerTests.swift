import Foundation
import Testing
@testable import CmuxMobileArtifacts

/// Two signed-in computers can expose an identical absolute file path while
/// serving different data. A thumbnail belongs to its authenticated reader,
/// including after the account changes inside one running iPhone process.
@Suite struct ArtifactMemoOwnerTests {
    let reference = TerminalArtifact(reference: "/repo/README.md", kind: .markdown)

    @Test func cacheKeyIncludesAccountMacAndResource() {
        let a = ArtifactThumbnailOwner.remote(accountID: "user-a", macID: "mac-1", resource: "agent-s1")
        let b = ArtifactThumbnailOwner.remote(accountID: "user-a", macID: "mac-2", resource: "agent-s1")
        let c = ArtifactThumbnailOwner.remote(accountID: "user-b", macID: "mac-1", resource: "agent-s1")
        let d = ArtifactThumbnailOwner.remote(accountID: "user-a", macID: "mac-1", resource: "agent-s2")
        #expect(a != nil && a != b && a != c && a != d)
        #expect(ArtifactThumbnailOwner.remote(accountID: "", macID: "mac-1", resource: "s1") == nil)
        #expect(ArtifactThumbnailOwner.remote(accountID: "u", macID: "", resource: "s1") == nil)
        #expect(ArtifactThumbnailOwner.remote(accountID: "u", macID: "m", resource: "") == nil)
        // Length-prefixing preserves distinct components even when a resource
        // contains the key separator.
        #expect(ArtifactThumbnailOwner.remote(accountID: "a|b", macID: "c", resource: "d")
                != ArtifactThumbnailOwner.remote(accountID: "a", macID: "b|c", resource: "d"))
    }

    @Test func twoMacsAndAccountsCannotReuseAnIdenticalPath() async {
        let cache = ArtifactMemo<String>(costLimit: 4_096)
        let a = ArtifactThumbnailOwner.remote(accountID: "a", macID: "mac-1", resource: "s")
        let b = ArtifactThumbnailOwner.remote(accountID: "a", macID: "mac-2", resource: "s")
        let otherAccount = ArtifactThumbnailOwner.remote(accountID: "b", macID: "mac-1", resource: "s")
        let first = await cache.value(for: reference, scope: a) { _ in "A private excerpt" }
        let second = await cache.value(for: reference, scope: b) { _ in "Mac B's file" }
        let third = await cache.value(for: reference, scope: otherAccount) { _ in "B account's file" }
        #expect(first == "A private excerpt")
        #expect(second == "Mac B's file")
        #expect(third == "B account's file")
        #expect(cache.makesStarted == 3)
        #expect(await cache.value(for: reference, scope: a) { _ in "should not read" } == "A private excerpt")
        #expect(await cache.value(for: reference, scope: b) { _ in "should not read" } == "Mac B's file")
        #expect(cache.makesStarted == 3)
    }

    @Test func anonymousSourceCannotReuseSharedCachedBytes() async {
        let cache = ArtifactMemo<String>(costLimit: 4_096)
        let first = await cache.value(for: reference, scope: nil) { _ in "first source" }
        let second = await cache.value(for: reference, scope: nil) { _ in "second source" }
        #expect(first == "first source" && second == "second source")
        #expect(cache.makesStarted == 0)
        #expect(cache.cached(reference, scope: nil) == nil)
    }

    @Test func signingOutPurgesThePreviousAccountsCompletedEntries() async {
        let cache = ArtifactMemo<String>(costLimit: 4_096)
        let old = ArtifactThumbnailOwner.remote(accountID: "a", macID: "m", resource: "s")
        #expect(await cache.value(for: reference, scope: old) { _ in "secret" } == "secret")
        cache.clear()
        #expect(cache.cached(reference, scope: old) == nil)
        #expect(await cache.value(for: reference, scope: old) { _ in "read again" } == "read again")
        #expect(cache.makesStarted == 2)
    }

    actor Hold {
        private var resume: CheckedContinuation<String?, Never>?
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []

        func read() async -> String? {
            await withCheckedContinuation { continuation in
                resume = continuation
                for waiter in startedWaiters { waiter.resume() }
                startedWaiters = []
            }
        }

        func waitUntilReading() async {
            if resume != nil { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func releaseOldBytes() {
            resume?.resume(returning: "old account")
            resume = nil
        }
    }

    @Test func aReadFinishingAfterLogoutCannotResurrectOldContent() async {
        let cache = ArtifactMemo<String>(costLimit: 4_096)
        let hold = Hold()
        let ref = reference
        let old = Task { await cache.value(for: ref, scope: "account-a") { _ in await hold.read() } }
        await hold.waitUntilReading()
        cache.clear()
        #expect(await cache.value(for: ref, scope: "account-a") { _ in "fresh session" } == "fresh session")
        await hold.releaseOldBytes()
        _ = await old.value
        #expect((cache.cached(ref, scope: "account-a") ?? nil) == "fresh session")
        #expect(cache.makesStarted == 2)
    }
}

#if os(iOS)
@Suite struct ArtifactThumbnailOwnerLiveTests {
    actor Source: ArtifactSource {
        nonisolated let thumbnailCacheScope: String?
        let contents: String
        private var reads = 0
        init(scope: String?, text: String) { thumbnailCacheScope = scope; contents = text }
        func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
            reads += 1
            return .text(contents)
        }
        func count() -> Int { reads }
    }

    @Test @MainActor func uncachedTileReloadsAnEditedFileWithoutReloadingOnReorder() {
        let source = Source(scope: nil, text: "inline preview")
        let first = TerminalArtifact(reference: "/repo/README.md", kind: .markdown, detail: "Edited · +1 −0")
        var edited = first
        edited.detail = "Edited · +2 −0"
        var reordered = edited
        reordered.order = 4

        let firstID = ArtifactTile(artifact: first, source: source).cacheTaskID
        let editedID = ArtifactTile(artifact: edited, source: source).cacheTaskID
        #expect(firstID != editedID)
        #expect(editedID == ArtifactTile(artifact: reordered, source: source).cacheTaskID)
    }

    @Test func actualThumbnailWrapperKeepsSamePathOnDifferentMacsSeparate() async {
        let memo = ArtifactMemo<ArtifactThumbnail>(costLimit: 8_192)
        let file = TerminalArtifact(reference: "/repo/README.md", kind: .markdown)
        let a = Source(scope: ArtifactThumbnailOwner.remote(accountID: "a", macID: "mac-a", resource: "chat"),
                       text: "private A")
        let b = Source(scope: ArtifactThumbnailOwner.remote(accountID: "a", macID: "mac-b", resource: "chat"),
                       text: "Mac B")
        #expect(await memo.thumbnail(for: file, source: a, scale: 2) == .excerpt("private A"))
        #expect(await memo.thumbnail(for: file, source: b, scale: 2) == .excerpt("Mac B"))
        #expect(await memo.thumbnail(for: file, source: a, scale: 2) == .excerpt("private A"))
        let firstReads = await a.count()
        let secondReads = await b.count()
        #expect(firstReads == 1 && secondReads == 1)
    }
}
#endif
