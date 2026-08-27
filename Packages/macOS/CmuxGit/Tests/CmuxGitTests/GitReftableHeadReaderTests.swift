import Foundation
import Testing
@testable import CmuxGit

/// The cost side of reftable support: the `git` fallback must stay off the
/// files backend entirely, and must not run again while the reftable stack is
/// unchanged.
@Suite struct GitReftableHeadReaderTests {
    @Test func filesBackendRepositoryNeverConsultsGit() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let reader = CountingGitReftableHeadReader()
        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            reftableHeadReader: reader
        )

        let metadata = await service.workspaceMetadata(for: fixture.root.path)
        let checkedOut = await service.checkedOutBranch(forDirectory: fixture.root.path)

        #expect(metadata.branch == "main")
        #expect(checkedOut == .branch("main"))
        #expect(reader.callCount == 0)
    }

    @Test func unreadableHeadOnFilesBackendNeverConsultsGit() async throws {
        let fixture = try GitRepositoryFixture()
        let reader = CountingGitReftableHeadReader()
        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            reftableHeadReader: reader
        )

        let checkedOut = await service.checkedOutBranch(forDirectory: fixture.root.path)

        #expect(checkedOut == .unreadable)
        #expect(reader.callCount == 0)
    }

    @Test(.enabled(if: ReftableRepositoryFixture.isSupported, "requires git with --ref-format=reftable"))
    func reftableStackSignatureChangesOnlyWhenRefsChange() async throws {
        let fixture = try ReftableRepositoryFixture(branch: "main")
        let reader = CountingGitReftableHeadReader(
            base: MemoizedGitReftableHeadReader(base: SystemGitReftableHeadReader())
        )
        let service = GitMetadataService(
            fileStatusReader: SystemGitFileStatusReader(),
            reftableHeadReader: reader
        )

        for _ in 0..<3 {
            #expect(await service.workspaceMetadata(for: fixture.root.path).branch == "main")
        }
        let signaturesBeforeCommit = reader.distinctStackSignatureCount
        try fixture.commitEmpty(message: "second")
        #expect(await service.workspaceMetadata(for: fixture.root.path).branch == "main")

        #expect(signaturesBeforeCommit == 1)
        #expect(reader.distinctStackSignatureCount == 2)
    }

    @Test func memoReusesResolutionUntilTheStackSignatureChanges() {
        let base = CountingGitReftableHeadReader(base: StubGitReftableHeadReader())
        let memo = MemoizedGitReftableHeadReader(base: base)

        _ = memo.head(workTreeRoot: "/repo", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/repo", stackSignature: "a")
        #expect(base.callCount == 1)

        _ = memo.head(workTreeRoot: "/repo", stackSignature: "b")
        #expect(base.callCount == 2)

        _ = memo.head(workTreeRoot: "/other", stackSignature: "a")
        #expect(base.callCount == 3)
    }

    @Test func memoRemembersAnUnresolvedReadOnlyBriefly() {
        let base = CountingGitReftableHeadReader()
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let memo = MemoizedGitReftableHeadReader(
            base: base,
            unresolvedTimeToLive: 5,
            now: { clock.now }
        )

        #expect(memo.head(workTreeRoot: "/repo", stackSignature: "a") == nil)
        clock.advance(by: 4)
        #expect(memo.head(workTreeRoot: "/repo", stackSignature: "a") == nil)
        #expect(base.callCount == 1)

        // A read fails for transient reasons too, so the same signature has to
        // become resolvable again rather than stay wrong until the refs move.
        clock.advance(by: 2)
        #expect(memo.head(workTreeRoot: "/repo", stackSignature: "a") == nil)
        #expect(base.callCount == 2)
    }

    @Test func memoKeepsAResolvedReadRegardlessOfTime() {
        let base = CountingGitReftableHeadReader(base: StubGitReftableHeadReader())
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let memo = MemoizedGitReftableHeadReader(
            base: base,
            unresolvedTimeToLive: 5,
            now: { clock.now }
        )

        _ = memo.head(workTreeRoot: "/repo", stackSignature: "a")
        clock.advance(by: 3_600)
        _ = memo.head(workTreeRoot: "/repo", stackSignature: "a")

        #expect(base.callCount == 1)
    }

    // Synchronous: the coordination is `DispatchGroup`/`DispatchSemaphore`, and
    // their blocking waits are unavailable from an async context.
    @Test func memoResolvesOnceWhenTwoCallersMissTheSameCheckout() throws {
        let base = BlockingGitReftableHeadReader()
        let memo = MemoizedGitReftableHeadReader(base: base)
        let results = ResultBox()
        let finished = DispatchGroup()

        finished.enter()
        let first = Thread {
            results.record(memo.head(workTreeRoot: "/repo", stackSignature: "a"))
            finished.leave()
        }
        first.start()
        // Every exit path frees the workers, including the failing ones: a
        // caller parked in the base reader or on the memo's condition would
        // otherwise outlive the test.
        defer { base.release() }
        try #require(base.waitUntilEntered(withinSeconds: 5))

        finished.enter()
        let second = Thread {
            results.record(memo.head(workTreeRoot: "/repo", stackSignature: "a"))
            finished.leave()
        }
        second.start()
        // The base reader signals on entry, so a second signal means the memo
        // let both callers resolve. This one has to not arrive; the deadline
        // is the window the second caller gets to reach the reader.
        #expect(base.waitUntilEntered(withinSeconds: 0.5) == false)

        base.release()
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(base.callCount == 1)
        #expect(results.values.allSatisfy { $0 == BlockingGitReftableHeadReader.resolvedHead })
    }

    @Test func memoEvictsTheOldestCheckoutBeyondItsBound() {
        let base = CountingGitReftableHeadReader(base: StubGitReftableHeadReader())
        let memo = MemoizedGitReftableHeadReader(base: base, maximumEntryCount: 2)

        _ = memo.head(workTreeRoot: "/first", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/second", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/third", stackSignature: "a")
        #expect(base.callCount == 3)

        // The two most recent stay cached, the first is gone.
        _ = memo.head(workTreeRoot: "/second", stackSignature: "a")
        _ = memo.head(workTreeRoot: "/third", stackSignature: "a")
        #expect(base.callCount == 3)

        _ = memo.head(workTreeRoot: "/first", stackSignature: "a")
        #expect(base.callCount == 4)
    }
}

/// Blocks inside `head` until released, so a second caller is guaranteed to
/// arrive while the first resolution is still in flight.
private final class BlockingGitReftableHeadReader: GitReftableHeadReading, @unchecked Sendable {
    static let resolvedHead = GitReftableHead(
        symbolicFullName: "refs/heads/main",
        objectID: String(repeating: "b", count: 40)
    )

    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        lock.lock()
        calls += 1
        lock.unlock()
        entered.signal()
        released.wait()
        return Self.resolvedHead
    }

    func waitUntilEntered(withinSeconds timeout: Double) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    /// Two permits, so a regression that lets a second caller into `head` fails
    /// the assertions instead of parking a thread forever.
    func release() {
        released.signal()
        released.signal()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Collects each caller's result across threads.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [GitReftableHead?] = []

    func record(_ head: GitReftableHead?) {
        lock.lock()
        results.append(head)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }

    var values: [GitReftableHead?] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

/// A hand-advanced wall clock, so expiry is tested without waiting.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(start: Date) {
        instant = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        instant += seconds
        lock.unlock()
    }
}

/// Resolves every checkout to the same fixed `HEAD`.
private struct StubGitReftableHeadReader: GitReftableHeadReading {
    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        GitReftableHead(
            symbolicFullName: "refs/heads/main",
            objectID: String(repeating: "a", count: 40)
        )
    }
}
