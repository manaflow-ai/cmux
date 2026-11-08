import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextHistoryDaemon
import Foundation
import Testing

/// cmux#38186 review: the daemon history's writes (visits and clears alike) wait in one ordered
/// queue for a live link. A write the link drops under is sent again on the next connect, never
/// thrown away, and a clear made while the daemon is away reaches it after the visits before it, so
/// they never come back.
@MainActor @Suite(.serialized) struct HistoryWriteQueueTests {
    /// The local daemon as the queue sees it: up or away, the visits it stores, and sends that fail
    /// as the link drops.
    @MainActor final class Daemon {
        var up = false
        var stored: [String] = []
        var attempts = 0
        /// The next this many sends fail as the link drops under them.
        var drops = 0
        var onDrop: (() -> Void)?
        private var waiters: [CheckedContinuation<Daemon?, Never>] = []

        func connected() async -> Daemon? {
            if up { return self }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func reconnect() {
            up = true
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume(returning: self) }
        }

        func send(_ change: @Sendable (inout [String]) -> Void) throws {
            attempts += 1
            if drops > 0 {
                drops -= 1
                up = false
                onDrop?()
                throw DaemonError.connectionClosed(reason: "link dropped")
            }
            change(&stored)
        }

        /// Keys the daemon committed (its mutation ledger: a retry of one changes nothing again), and the
        /// key of every send in order.
        var committed: Set<String> = []
        var keys: [String] = []
        /// The next this many keyed sends commit, then their reply is lost (`timedOut`).
        var lostReplies = 0

        /// What a lost reply throws: a timeout, or a reply that does not parse.
        var lostReply = DaemonError.timedOut("history.visit.record")

        func send(key: String, _ change: @Sendable (inout [String]) -> Void) throws {
            attempts += 1
            keys.append(key)
            if committed.insert(key).inserted { change(&stored) }
            if lostReplies > 0 {
                lostReplies -= 1
                throw lostReply
            }
        }

        /// Runs once during the next ``list()`` (a clear queued while a read is under way).
        var onRead: (() -> Void)?

        /// A read of the stored visits (the omnibox seed's summaries).
        func list() -> [String] {
            onRead?()
            onRead = nil
            return stored
        }

        func refuse() throws {
            attempts += 1
            throw DaemonError.command(cmd: "history.clear", message: "invalid range", code: "cmux.invalid_params")
        }
    }

    static func queue(_ daemon: Daemon) -> HistoryWriteQueue<Daemon> {
        HistoryWriteQueue(backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(40)),
                          retryable: DaemonHistoryClient.isLinkDrop) { await daemon.connected() }
    }

    /// Queues `write` and waits until it was sent (or refused).
    static func sent(_ queue: HistoryWriteQueue<Daemon>, visit: Bool = false, _ write: @escaping HistoryWriteQueue<Daemon>.Write) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.enqueue(visit: visit, write) { done.resume() }
        }
    }

    @Test func aWriteTheLinkDropsUnderIsSentAgainAfterTheReconnect() async {
        let daemon = Daemon()
        daemon.up = true
        daemon.drops = 1
        daemon.onDrop = { Task { @MainActor in daemon.reconnect() } }
        let queue = Self.queue(daemon)
        await Self.sent(queue, visit: true) { client, _ in try await client.send { $0.append("https://a.example/") } }
        #expect(daemon.stored == ["https://a.example/"])
        #expect(daemon.attempts == 2, "the dropped send was not sent again")
        #expect(queue.count == 0)
    }

    @Test func aClearMadeOfflineReachesTheDaemonAfterTheVisitsBeforeIt() async {
        let daemon = Daemon()
        let queue = Self.queue(daemon)
        queue.enqueue(visit: true) { client, _ in try await client.send { $0.append("https://cleared.example/") } }
        queue.enqueue { client, _ in try await client.send { $0.removeAll() } }
        #expect(queue.count == 2)
        daemon.reconnect()
        await Self.sent(queue, visit: true) { client, _ in try await client.send { $0.append("https://after.example/") } }
        #expect(daemon.stored == ["https://after.example/"], "a visit queued before the clear came back")
    }

    @Test func aRefusedWriteIsNotSentAgain() async {
        let daemon = Daemon()
        daemon.up = true
        let queue = Self.queue(daemon)
        await Self.sent(queue) { client, _ in try await client.refuse() }
        #expect(daemon.attempts == 1)
        #expect(queue.count == 0)
    }

    @Test func pastCapacityAWaitingVisitGoesNeverAClear() async {
        let daemon = Daemon()
        daemon.stored = ["before"]
        let queue = HistoryWriteQueue<Daemon>(capacity: 2, retryable: DaemonHistoryClient.isLinkDrop) { await daemon.connected() }
        queue.enqueue { client, _ in try await client.send { $0.removeAll() } }
        queue.enqueue(visit: true) { client, _ in try await client.send { $0.append("old") } }
        // Nothing has run yet: the third write makes room by dropping the waiting visit, not the clear.
        daemon.reconnect()
        await Self.sent(queue, visit: true) { client, _ in try await client.send { $0.append("new") } }
        #expect(daemon.stored == ["new"])
    }

    /// cmux#38186 review: with only clears and removes waiting, a new visit is refused for room; none of
    /// them is dropped, and a new clear still goes in past the capacity.
    @Test func pastCapacityWithOnlyClearsWaitingTheNewVisitIsRefused() async {
        let daemon = Daemon()
        let queue = HistoryWriteQueue<Daemon>(capacity: 2, retryable: DaemonHistoryClient.isLinkDrop) { await daemon.connected() }
        queue.enqueue { client, _ in try await client.send { $0.append("clear-a") } }
        queue.enqueue { client, _ in try await client.send { $0.append("clear-b") } }
        queue.enqueue(visit: true) { client, _ in try await client.send { $0.append("visit") } }
        #expect(queue.count == 2, "a visit took the place of a clear")
        queue.enqueue { client, _ in try await client.send { $0.append("clear-c") } }
        #expect(queue.count == 3, "a clear was dropped for room")
        daemon.reconnect()
        await Self.sent(queue) { client, _ in try await client.send { $0.append("last") } }
        #expect(daemon.stored == ["clear-a", "clear-b", "clear-c", "last"])
    }

    /// cmux#38186 review: a profile's legacy import (queued `ahead`) reaches the daemon before a clear made
    /// while it was away, so the clear removes the imported visits instead of the import restoring them.
    @Test func anImportQueuedAheadGoesBeforeAnOfflineClear() async {
        let daemon = Daemon()
        let queue = Self.queue(daemon)
        queue.enqueue { client, _ in try await client.send { $0.removeAll() } }
        queue.enqueue(ahead: true) { client, _ in try await client.send { $0.append("legacy") } }
        daemon.reconnect()
        await Self.sent(queue, visit: true) { client, _ in try await client.send { $0.append("after") } }
        #expect(daemon.stored == ["after"], "the legacy import came after the clear and restored its visits")
    }

    /// cmux#38186 review: a queued clear carries the absolute start taken at the click (range `today`
    /// from `local_day_start_ms`), so its delivery an hour later still clears from the click's hour.
    @Test func aClearCarriesTheClickTimeStart() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let params = DaemonHistoryClient.clearParams(kinds: [.page], since: since, profile: "default")
        #expect(params["range"] == .string("today"))
        #expect(params["local_day_start_ms"] == .string("1700000000000"))
        #expect(params["profile"] == .string("default"))
        let all = DaemonHistoryClient.clearParams(kinds: [], since: nil, profile: nil)
        #expect(all["range"] == .string("all"))
        #expect(all["local_day_start_ms"] == nil)
        #expect(all["until_ms"] == nil)
    }

    /// cmux#38186 review: a queued clear also carries the click as its end (`until_ms`), so an agent active
    /// between the click and the delivery stays (the daemon side: cmux-tui
    /// `a_queued_agent_clear_keeps_a_session_active_after_its_click`).
    @Test func aClearCarriesTheClickTimeEnd() {
        let click = Date(timeIntervalSince1970: 1_700_003_600)
        let params = DaemonHistoryClient.clearParams(kinds: [.agent], since: Date(timeIntervalSince1970: 1_700_000_000), until: click, profile: nil)
        #expect(params["until_ms"] == .string("1700003600000"))
        #expect(params["local_day_start_ms"] == .string("1700000000000"))
        #expect(DaemonHistoryClient.clearUntilCapability == "history-clear-until-v1")
    }

    /// cmux#38186 review: with the local daemon away, a connected remote daemon's command rows (its mirror
    /// in `commands`) still list in history and resolve by id; only the local daemon's kinds are unavailable.
    @Test func remoteCommandsListWhileTheLocalDaemonIsAway() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let command = TerminalCommand(id: 7, machine: "ssh-box", terminal: "term_1", command: "make test", cwd: "/src", exitCode: 0,
                                      startedAt: Date().addingTimeInterval(-30), duration: 1)
        var mirror = TerminalCommandMirror(machine: "ssh-box")
        let applied = mirror.apply([command], version: "v1", truncated: false, after: nil)
        #expect(applied)
        services.history.commands.mirrors["ssh-box"] = mirror
        #expect(services.history.daemonHistory == nil)
        let read = await services.history.read(HistoryQuery())
        #expect(read.entries.map(\.id) == ["command:\(command.qualifiedID)"])
        #expect(read.unavailable, "the local daemon's kinds read as empty, not unavailable")
        let commandsOnly = await services.history.read(HistoryQuery(kinds: [.command]))
        #expect(commandsOnly.entries.count == 1)
        #expect(!commandsOnly.unavailable)
        let entry = await services.history.entry(id: "command:\(command.qualifiedID)")
        #expect(entry?.title == "make test")
    }

    /// cmux#38186 review: a write whose reply never came (`timedOut`) goes again, with the same key, so a
    /// visit the daemon did commit is answered from its ledger and counted once, never dropped or doubled.
    @Test func aTimedOutWriteGoesAgainWithItsKeyAndCountsOnce() async {
        let daemon = Daemon()
        daemon.up = true
        daemon.lostReplies = 1
        let queue = Self.queue(daemon)
        await Self.sent(queue, visit: true) { client, key in try await client.send(key: key) { $0.append("https://a.example/") } }
        #expect(DaemonHistoryClient.isLinkDrop(DaemonError.timedOut("history.clear")))
        #expect(daemon.attempts == 2, "a timed-out write was dropped, not sent again")
        #expect(Set(daemon.keys).count == 1, "the retry carried a new key")
        #expect(daemon.stored == ["https://a.example/"])
    }

    /// cmux#38186 review: a reply that does not parse leaves the outcome unknown (the write may have committed):
    /// the write goes again with the same key instead of being dropped as a refusal, and counts once.
    @Test func aMalformedReplyIsSentAgainWithItsKey() async {
        let daemon = Daemon()
        daemon.up = true
        daemon.lostReplies = 1
        daemon.lostReply = .malformedResponse("unexpected end of JSON")
        let queue = Self.queue(daemon)
        await Self.sent(queue, visit: true) { client, key in try await client.send(key: key) { $0.append("https://a.example/") } }
        #expect(!DaemonHistoryClient.isRefusal(DaemonError.malformedResponse("x")))
        #expect(daemon.attempts == 2, "a write with a malformed reply was dropped as a refusal")
        #expect(Set(daemon.keys).count == 1)
        #expect(daemon.stored == ["https://a.example/"])
    }

    /// A reply that is always malformed (the daemon replays the same one for the key) is tried a bounded number of
    /// times, then dropped, so the queue moves on to the writes behind it.
    @Test func anAlwaysMalformedReplyIsDroppedAfterBoundedAttempts() async {
        let daemon = Daemon()
        daemon.up = true
        daemon.lostReplies = 100
        daemon.lostReply = .malformedResponse("unexpected end of JSON")
        let queue = HistoryWriteQueue<Daemon>(backoff: .init(initial: .milliseconds(5), maximum: .milliseconds(10)),
                                              retryable: DaemonHistoryClient.isLinkDrop, unknownAttempts: 3) { await daemon.connected() }
        await Self.sent(queue) { client, key in try await client.send(key: key) { $0.append("clear") } }
        #expect(daemon.attempts == 3)
        #expect(queue.count == 0)
        #expect(daemon.stored == ["clear"])
    }

    /// cmux#38186 review: a legacy import the link drops under throws the drop (so ``writes`` sends it
    /// again and seeds only after it), and the app-local log stays for that retry.
    @Test func aLegacyImportTheLinkDropsUnderThrowsTheDrop() async throws {
        // The real path: the legacy file refuses a path through a symlink (macOS's /var -> /private/var).
        let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let support = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appending(path: "cmux-history-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        let log = LegacyHistoryFile.visitLogURL(profile: "default", supportDirectory: support)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: log)
        let offline = DaemonHistoryClient(connection: DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-history-import-\(UUID().uuidString).sock")))
        var thrown: (any Error)?
        do { try await HistoryService.handOver(log, supportDirectory: support, profile: "default", to: offline) } catch { thrown = error }
        let error = try #require(thrown, "a failed import looked like a finished one")
        #expect(DaemonHistoryClient.isLinkDrop(error), "\(error)")
        #expect(FileManager.default.fileExists(atPath: log.path))
    }

    /// cmux#38186 review, the exact sequence: a legacy log, the omnibox seed queued at launch, then a clear made
    /// before the daemon connects. The import goes first and the seed reads before the clear runs, but the clear
    /// was queued after the seed: the seed reads again behind it, so the merge never brings the cleared visits back.
    @Test func aSeedQueuedBeforeAnOfflineClearReadsAgainBehindIt() async {
        let daemon = Daemon()
        let queue = Self.queue(daemon)
        let seeded: [String] = await withCheckedContinuation { seeded in
            queue.enqueue(ahead: true) { client, _ in try await client.send { $0.append("https://legacy.example/") } }
            queue.read({ await $0.list() }, use: { seeded.resume(returning: $0) })
            queue.enqueue { client, _ in try await client.send { $0.removeAll() } }
            daemon.reconnect()
        }
        #expect(seeded.isEmpty, "the seed merged visits the clear removed")
        #expect(daemon.stored.isEmpty)
    }

    /// The other order: a clear queued while the seed's read is under way also sends the read again behind it.
    @Test func aClearQueuedWhileTheSeedReadsSendsItAgain() async {
        let daemon = Daemon()
        daemon.up = true
        daemon.stored = ["https://a.example/"]
        let queue = Self.queue(daemon)
        daemon.onRead = { queue.enqueue { client, _ in try await client.send { $0.removeAll() } } }
        let seeded: [String] = await withCheckedContinuation { seeded in
            queue.read({ await $0.list() }, use: { seeded.resume(returning: $0) })
        }
        #expect(seeded.isEmpty, "a read answered before the clear was used after it")
    }

    /// The app's own wiring: the omnibox seed's read, an omnibox visit and a Clear History wait in the same
    /// queue while the local daemon is away (no daemon in this test).
    @Test func visitsAndClearsShareTheAppsQueue() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.history.attach(services.cache.history, profile: .default)
        #expect(services.history.writes.count == 1, "the seed's read is not in the queue")
        services.cache.history.recordVisit(url: try #require(URL(string: "https://a.example/")), title: "A", at: Date())
        #expect(services.history.writes.count == 2)
        services.history.clear(kinds: [.page], range: .all)
        #expect(services.history.writes.count == 3)
    }
}
