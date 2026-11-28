import CmuxNextDaemon
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

    /// A real child, as `casFetcher` runs the CLI (``BundledCLIRun``): a script that writes its pid
    /// and then holds like a fetch stalled on a slow Range GET. The link turns once the pid is on
    /// disk; the fetch must end as `linkLost` and the child must be gone, not left running to its
    /// own timeout (RFD 0166 F3: a path change mid-fetch).
    @Test func aLinkLostMidFetchKillsTheRealChild() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (script, pidFile) = try Self.holdingChild(in: root)
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, watch: Self.turnsAfter {
            _ = await Self.pid(in: pidFile, within: .seconds(10))
        }) {
            await BundledCLIRun.run(script, [], timeout: .seconds(60))
        }
        guard case .linkLost = ended else { Issue.record("expected linkLost, got \(ended)"); return }
        let pid = try #require(await Self.pid(in: pidFile, within: .seconds(1)))
        #expect(await Self.gone(pid, within: .seconds(2)), "the CLI child \(pid) outlived its cancelled fetch")
    }

    /// The same real child under a link that holds runs to its own end and reports it.
    @Test func aLinkThatHoldsLetsTheRealChildFinish() async throws {
        let root = try WebUpdateStoreTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (script, _) = try Self.holdingChild(in: root, holdSeconds: 0)
        let ended = await WebUpdates.runWhileLinkAllows(Self.request, watch: Self.turnsAfter { await Self.untilCancelled() }) {
            await BundledCLIRun.run(script, [], timeout: .seconds(60))
        }
        guard case .ran(let result) = ended else { Issue.record("expected ran, got \(ended)"); return }
        #expect(result?.status == 0)
    }

    /// An executable script in `root` that writes its pid to `pid` and then holds for
    /// `holdSeconds` as that same process (`exec`), so the pid on disk is the child the run kills.
    nonisolated static func holdingChild(in root: URL, holdSeconds: Int = 60) throws -> (URL, URL) {
        let script = root.appending(path: "fetch.sh"), pid = root.appending(path: "fetch.pid")
        try "#!/bin/sh\necho $$ > '\(pid.path)'\nexec /bin/sleep \(holdSeconds)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, pid)
    }

    /// The pid `file` holds once the child wrote it, nil if it did not within `bound`.
    nonisolated static func pid(in file: URL, within bound: Duration) async -> pid_t? {
        let clock = ContinuousClock(), end = clock.now.advanced(by: bound)
        while clock.now < end {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// Whether `pid` no longer exists within `bound` (ProcessRunner reaps it, so no zombie holds it).
    nonisolated static func gone(_ pid: pid_t, within bound: Duration) async -> Bool {
        let clock = ContinuousClock(), end = clock.now.advanced(by: bound)
        while clock.now < end {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}
