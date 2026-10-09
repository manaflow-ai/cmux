import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// Messages parity for a send made while the owner is briefly gone (the
/// Chief owner or brain restarting, a build reconnecting): the send waits
/// as "sending" and goes under its key at the reconnect. It shows "Not
/// Delivered" only when the owner stays gone past `offlineSendDeadline`;
/// a tap (`retry`) then sends it again. Live incident 2026-10-09 (nxdog81).
@MainActor
@Suite struct OfflineSendQueueTests {
    let conversation = ConversationID("conv_austin")

    func started(clock: any Clock<Duration> = ContinuousClock()) async throws -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory(), clock: clock)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        return (store, source)
    }

    func row(_ store: HomeStore, _ key: IdempotencyKey) -> TranscriptItem? {
        store.transcript(for: conversation).first { $0.key == key }
    }

    @Test func aSendWhileTheOwnerIsGoneWaitsAndGoesAtTheReconnect() async throws {
        let (store, source) = try await started()
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        let key = IdempotencyKey("offline-send-1")
        await #expect(throws: HomeSendState.pendingResend) {
            try await store.perform(.sendMessage(conversation: conversation, parts: [.text("while away")]), key: key)
        }
        #expect(row(store, key)?.delivery == .sending)

        await source.setOnline(true)
        await waitUntil { self.row(store, key)?.delivery == .committed }
        #expect(row(store, key)?.seq != nil)
        store.stop()
    }

    @Test func sendsMadeWhileGoneCommitInTheOrderMade() async throws {
        let (store, source) = try await started()
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        let keys = (1...3).map { IdempotencyKey("offline-order-\($0)") }
        for (index, key) in keys.enumerated() {
            _ = try? await store.perform(.sendMessage(conversation: conversation, parts: [.text("m\(index)")]), key: key)
        }
        await source.setOnline(true)
        await waitUntil { keys.allSatisfy { self.row(store, $0)?.delivery == .committed } }
        let seqs = keys.compactMap { row(store, $0)?.seq }
        #expect(seqs.count == 3)
        #expect(seqs == seqs.sorted())
        store.stop()
    }

    @Test func aSendFailsOnlyWhenTheOwnerStaysGonePastTheDeadline() async throws {
        let clock = ManualClock()
        let (store, source) = try await started(clock: clock)
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        let key = IdempotencyKey("offline-deadline")
        let sleepers = clock.pendingSleepers
        _ = try? await store.perform(.sendMessage(conversation: conversation, parts: [.text("long gone")]), key: key)
        // The deadline's sleep is registered before the clock moves.
        await waitUntil { clock.pendingSleepers > sleepers }

        clock.advance(by: HomeStore.offlineSendDeadline - .seconds(1))
        for _ in 0..<500 { await Task.yield() }
        #expect(row(store, key)?.delivery == .sending)

        clock.advance(by: .seconds(2))
        await waitUntil { self.row(store, key)?.delivery == .notDelivered(.ownerUnreachable) }
        // It never reached the owner: "Not Delivered", not "may not have been".
        #expect(row(store, key)?.mayHaveBeenDelivered == false)

        // A tap after the owner is back sends it.
        await source.setOnline(true)
        await waitUntil { store.isOnline }
        try? await store.retry(key)
        await waitUntil { self.row(store, key)?.delivery == .committed }
        store.stop()
    }

    @Test func otherOpsAreStillRefusedWhileTheOwnerIsGone() async throws {
        let (store, source) = try await started()
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.perform(.setReadCursor(conversation: conversation, seq: 1))
        }
        #expect(store.log.isEmpty)
        store.stop()
    }
}
