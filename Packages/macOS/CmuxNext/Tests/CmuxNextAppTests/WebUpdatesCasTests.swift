@testable import CmuxNextUpdater
@testable import CmuxNextWebUpdates
import Foundation
import Testing

/// The app's `cas/1` fetch (WebUpdates+Cas.swift, RFD 0166): without the bundled CLI it is a miss
/// that names why (`last_fetch.cas_miss`), and a link that stops allowing the fetch midway cancels
/// it, as the archive's download does.
@Suite(.serialized) @MainActor struct WebUpdatesCasTests {
    static let request = WebUpdater.CasRequest(
        manifest: "m.json", pack: "p.pack", base: URL(string: "https://files.cmux.com/cas/1/")!, have: [],
        chunks: URL(filePath: "/tmp/chunks"), out: URL(filePath: "/tmp/out"), allowsConstrained: false, allowsExpensive: true)

    /// Waits until cancelled.
    nonisolated static func untilCancelled() async {
        for await _ in AsyncStream<Never>(Never.self, { _ in }) {}
    }

    @Test func withoutTheBundledCLIAFetchIsAMissThatSaysSo() async {
        let fetch = WebUpdates().casFetcher()
        #expect(await fetch(Self.request) == .failure(.init("no bundled cmux CLI")))
    }

    @Test func withoutTheBundledCLITheArchiveIsTakenAndTheMissRecorded() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, _, updater, pointer) = try await WebUpdaterTests.casSetup(root)
        updater.casFetch = WebUpdates().casFetcher()
        await updater.check()
        #expect(server.downloads == 1)
        #expect(updater.state.active == pointer)
        #expect(updater.lastFetch?.by == .archive)
        #expect(updater.lastFetch?.casMiss == "no bundled cmux CLI")
    }

    /// A watcher that allows the fetch, then waits for `turn` and stops allowing it.
    nonisolated static func turnsAfter(_ turn: @escaping @Sendable () async -> Void)
        -> @Sendable (WebUpdater.CasRequest, (Bool) -> Bool) async -> Void {
        { _, each in
            guard each(true) else { return }
            await turn()
            _ = each(false)
        }
    }

    @Test func aLinkLostMidFetchCancelsTheFetch() async {
        let started = AsyncStream.makeStream(of: Void.self)
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, watch: Self.turnsAfter {
            for await _ in started.stream { return }
        }) { () -> Bool in
            started.continuation.yield()
            await Self.untilCancelled()
            return Task.isCancelled
        }
        guard case .linkLost = ended else { Issue.record("expected linkLost, got \(ended)"); return }
    }

    @Test func aLinkThatNeverAllowsTheFetchNeverStartsIt() async {
        let ran = Counter()
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, watch: { _, each in _ = each(false) }) { ran.add() }
        guard case .metered = ended else { Issue.record("expected metered, got \(ended)"); return }
        #expect(ran.value == 0)
    }

    @Test func aFetchThatEndsFirstStopsTheLinkWatch() async {
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, watch: Self.turnsAfter { await Self.untilCancelled() }) { 7 }
        guard case .ran(let value) = ended else { Issue.record("expected ran, got \(ended)"); return }
        #expect(value == 7)
    }

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}
