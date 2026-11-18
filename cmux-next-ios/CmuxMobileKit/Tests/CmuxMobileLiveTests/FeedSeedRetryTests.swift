import CmuxConnectivityTelemetry
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Audit 17 (fallbacks that hide a failure): a chat waiting on an ask whose records could not be
/// read showed "Needs you" with no card, and the failure was dropped. Now the failure is logged
/// with its reason, the Feed's Needs you row says it plainly while it is read again, and the
/// card takes its place once the read succeeds.
@MainActor
@Suite struct FeedSeedRetryTests {
    nonisolated static let waiting = #"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"waiting","pendingPermissions":1,"lastSeq":3}]}"#
    nonisolated static let events = #"{"events":[{"sessionId":"s1","seq":3,"kind":"permission_request","msg":{"permissionId":"perm","request":{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}]}"#

    /// How many `_acpmux/events` reads fail before one succeeds.
    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        private(set) var reads = 0
        init(_ count: Int) { left = count }
        func next() -> Bool {
            lock.withLock {
                reads += 1
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
    }

    static func mac(failing failures: Failures) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(waiting)]
            case "_acpmux/events":
                if failures.next() {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"event log busy"}}"#.utf8)]
                }
                return [reply(events)]
            default: return [reply("{}")]
            }
        }
    }

    /// A hub and Feed wired as the app wires them (`LiveCoordinator+Links.swift`), telemetry
    /// going to a journal the test reads, retries a few milliseconds apart.
    static func wired(_ failures: Failures, delays: [Duration] = [.milliseconds(20)])
        async throws -> (AcpmuxHub, FeedStore, ConnectivityTelemetry, ConnectivityJournal) {
        let telemetry = ConnectivityTelemetry()
        telemetry.setAudience(.team)
        let journal = ConnectivityJournal(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-retry-\(UUID().uuidString)", isDirectory: true))
        telemetry.setJournal(journal)
        let hub = AcpmuxHub()
        hub.telemetry = telemetry
        hub.seedRetryDelays = delays
        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        hub.onWatchEvent = { [weak hub] event in
            guard let hub else { return }
            feed.handle(event, sessions: hub.sessions)
        }
        await hub.bind(try await mac(failing: failures).openChannel(service: "acpmux", args: [:]))
        return (hub, store, telemetry, journal)
    }

    static func settle(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: waits for the retry, to a deadline
        }
    }

    /// Detector: on the old code the failed read was dropped (`try?`), so no card ever came
    /// and nothing was logged.
    @Test func aSeedThatThrowsThenSucceedsEndsWithTheCardAndOneLogRecord() async throws {
        let failures = Failures(1)
        let (_, store, telemetry, journal) = try await Self.wired(failures)
        await Self.settle { store.item(id: "ask-perm") != nil }
        #expect(store.item(id: "ask-perm")?.needsYou == true)
        #expect(store.item(id: LiveFeed.unreadAsksID("s1")) == nil)
        #expect(store.needsYouIDs == ["ask-perm"])
        #expect(failures.reads == 2)
        await telemetry.flush()
        let failed = journal.records().filter { $0.name == "seed_pending_failed" }
        #expect(failed.count == 1)
        #expect(failed.first?.outcome == .failure)
        #expect(failed.first?.fields["attempt"] == .number(1))
    }

    /// The same with the app's own retry delays and telemetry, through nothing but the hub's and
    /// the Feed's public wiring: this one compiles on the old code, where it fails (no card).
    @Test func aSeedThatThrowsOnceStillEndsWithTheCard() async throws {
        let failures = Failures(1)
        let hub = AcpmuxHub()
        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        hub.onWatchEvent = { [weak hub] event in
            guard let hub else { return }
            feed.handle(event, sessions: hub.sessions)
        }
        await hub.bind(try await Self.mac(failing: failures).openChannel(service: "acpmux", args: [:]))
        await Self.settle { store.item(id: "ask-perm") != nil }
        #expect(store.item(id: "ask-perm")?.needsYou == true)
        #expect(failures.reads == 2)
    }

    /// While the read fails, the Needs you row says why and that it is read again: no empty card.
    @Test func whileTheReadFailsTheRowSaysWhy() async throws {
        let failures = Failures(100)
        let (_, store, _, _) = try await Self.wired(failures, delays: [.seconds(60)])
        await Self.settle { store.item(id: LiveFeed.unreadAsksID("s1")) != nil }
        let row = try #require(store.item(id: LiveFeed.unreadAsksID("s1")))
        #expect(row.needsYou)
        #expect(row.markdown.hasPrefix("Couldn't load the question: "))
        #expect(row.markdown.hasSuffix(". Retrying."))
        #expect(row.markdown.localizedCaseInsensitiveContains("event log busy"))
        #expect(store.needsYouIDs == [LiveFeed.unreadAsksID("s1")])
    }

    /// Retries are bounded: after the last one the row says how to get it, and reads stop.
    @Test func retriesAreBounded() async throws {
        let failures = Failures(100)
        let (_, store, telemetry, journal) = try await Self.wired(failures, delays: [.milliseconds(5), .milliseconds(5)])
        await Self.settle { store.item(id: LiveFeed.unreadAsksID("s1"))?.markdown.hasSuffix("Retrying.") == false }
        try? await Task.sleep(for: .milliseconds(100)) // test: no read after the last retry
        #expect(failures.reads == 3)
        #expect(store.item(id: LiveFeed.unreadAsksID("s1"))?.markdown.hasSuffix("Pull to refresh to try again.") == true)
        await telemetry.flush()
        #expect(journal.records().filter { $0.name == "seed_pending_failed" }.count == 3)
    }

    /// A new connection reads the asks again, and the card replaces the row.
    @Test func aReconnectReadsTheAsksAgain() async throws {
        let failures = Failures(1)
        let (hub, store, _, _) = try await Self.wired(failures, delays: [])
        await Self.settle { store.item(id: LiveFeed.unreadAsksID("s1"))?.markdown.hasSuffix("Pull to refresh to try again.") == true }
        #expect(store.item(id: "ask-perm") == nil)
        await hub.bind(try await Self.mac(failing: failures).openChannel(service: "acpmux", args: [:]))
        await Self.settle { store.item(id: "ask-perm") != nil }
        #expect(store.item(id: "ask-perm") != nil)
        #expect(store.item(id: LiveFeed.unreadAsksID("s1")) == nil)
    }
}
