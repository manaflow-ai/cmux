import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// A send whose owner is down while the merged connection stays online (the
/// router under an online cloud, the local Chief owner restarting): the
/// source sends nothing (`HomeOwnerOffline`). The row shows "sending", goes
/// at the owner's recovery, and fails "Not Delivered" past the deadline,
/// never "May Not Have Been Delivered" (it never left).
@MainActor
@Suite struct OwnerAbsentSendTests {
    let conversation = ConversationID("conv_austin")

    func started(clock: any Clock<Duration> = ContinuousClock()) async throws -> (HomeStore, AbsentOwnerSource) {
        let source = AbsentOwnerSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source, blobCacheDirectory: try temporaryDirectory(), clock: clock)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        await store.open(conversation)
        return (store, source)
    }

    func row(_ store: HomeStore, _ key: IdempotencyKey) -> TranscriptItem? {
        store.transcript(for: conversation).first { $0.key == key }
    }

    @Test func aSendTheOwnerNeverGotWaitsAndGoesAtItsRecovery() async throws {
        let (store, source) = try await started()
        source.setAbsent(true)
        let key = IdempotencyKey("absent-send-1")
        await #expect(throws: HomeSendState.pendingResend) {
            try await store.perform(.sendMessage(conversation: conversation, parts: [.text("owner down")]), key: key)
        }
        #expect(store.isOnline)
        #expect(row(store, key)?.delivery == .sending)

        source.setAbsent(false)
        await waitUntil { self.row(store, key)?.delivery == .committed }
        store.stop()
    }

    @Test func aSendTheOwnerNeverGotIsNotDeliveredPastTheDeadline() async throws {
        let clock = ManualClock()
        let (store, source) = try await started(clock: clock)
        source.setAbsent(true)
        let key = IdempotencyKey("absent-send-deadline")
        let sleepers = clock.pendingSleepers
        _ = try? await store.perform(.sendMessage(conversation: conversation, parts: [.text("owner gone")]), key: key)
        await waitUntil { clock.pendingSleepers > sleepers }

        clock.advance(by: HomeStore.offlineSendDeadline - .seconds(1))
        for _ in 0..<500 { await Task.yield() }
        #expect(row(store, key)?.delivery == .sending)

        clock.advance(by: .seconds(2))
        await waitUntil { self.row(store, key)?.delivery == .notDelivered(.ownerUnreachable) }
        #expect(row(store, key)?.mayHaveBeenDelivered == false)
        store.stop()
    }

    @Test func anotherOpTheOwnerNeverGotIsRefusedAndLeavesNothing() async throws {
        let (store, source) = try await started()
        source.setAbsent(true)
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.perform(.setReadCursor(conversation: conversation, seq: 1))
        }
        #expect(store.log.isEmpty)
        store.stop()
    }
}

/// A source over the mock whose owner can be absent: every submit and
/// upload then sends nothing (`HomeOwnerOffline`) while the connection stays
/// online, and the owner's return publishes `.ownerRecovered`.
final class AbsentOwnerSource: HomeSource, @unchecked Sendable {
    private let inner: MockHomeSource
    private let lock = NSLock()
    private var absent = false
    private var continuations: [AsyncStream<HomeEvent>.Continuation] = []

    init(_ inner: MockHomeSource) { self.inner = inner }

    func setAbsent(_ value: Bool) {
        let recovered = lock.withLock { () -> [AsyncStream<HomeEvent>.Continuation] in
            defer { absent = value }
            return absent && !value ? continuations : []
        }
        for continuation in recovered { continuation.yield(.ownerRecovered) }
    }

    private func requireOwner() throws {
        if lock.withLock({ absent }) { throw HomeOwnerOffline() }
    }

    func events() async -> AsyncStream<HomeEvent> {
        let upstream = await inner.events()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream()
        lock.withLock { continuations.append(continuation) }
        let forward = Task {
            for await event in upstream { continuation.yield(event) }
            continuation.finish()
        }
        continuation.onTermination = { _ in forward.cancel() }
        return stream
    }

    func inbox() async throws -> InboxSnapshot { try await inner.inbox() }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try await inner.snapshot(of: conversation, tail: tail)
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await inner.history(of: conversation, before: beforeSeq, limit: limit)
    }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        try requireOwner()
        return try await inner.submit(intent)
    }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await inner.search(query, limit: limit) }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await inner.resolve(contact) }
    func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        try requireOwner()
        return try await inner.upload(file)
    }
    func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        try await inner.fetch(ref, at: location, variant: variant)
    }
    func close(_ conversation: ConversationID) {}
}
