import Foundation
import os
import Testing
@testable import CmuxConversationCore

/// The Chief header said "Connecting…" and the transcript span its spinner
/// forever when no connection ever came. After `connectDeadline` the store
/// now reports `.failed` (the screen shows "Couldn't connect" with Retry);
/// a later connection replaces it, and Retry starts over.
@MainActor
@Suite struct ConversationConnectionDeadlineTests {
    static func store(_ backend: any ConversationBackend, clock: DeadlineTestClock) -> ConversationStore {
        ConversationStore(backend: backend, pageSize: 30, connectionClock: clock, connectDeadline: .seconds(15))
    }

    @Test func noConnectionWithinTheDeadlineFails() async throws {
        let backend = ReconnectingTestBackend()
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.start()
        try await waitUntil { clock.pendingSleepers == 1 }
        #expect(store.connection == .connecting)

        clock.advance(by: .seconds(14))
        await Task.yield()
        #expect(store.connection == .connecting)

        clock.advance(by: .seconds(1))
        try await waitUntil { store.connection == .failed }
        #expect(changes.contains(.connection))
        store.stop()
    }

    @Test func aConnectionAfterTheDeadlineReplacesTheFailure() async throws {
        let backend = ReconnectingTestBackend()
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        store.start()
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(15))
        try await waitUntil { store.connection == .failed }

        backend.emit(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.connection == .connected }
        store.stop()
    }

    @Test func aConnectionInTimeNeverFails() async throws {
        let backend = ReconnectingTestBackend()
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        store.start()
        try await waitUntil { clock.pendingSleepers == 1 }
        backend.emit(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.connection == .connected }
        // The deadline was cancelled with the connection.
        try await waitUntil { clock.pendingSleepers == 0 }
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(store.connection == .connected)
        store.stop()
    }

    @Test func retryStartsOverAndAsksTheBackendToDialNow() async throws {
        let backend = ReconnectingTestBackend()
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        store.start()
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(15))
        try await waitUntil { store.connection == .failed }

        store.retryConnection()
        #expect(store.connection == .connecting)
        #expect(backend.reconnects == 1)
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(15))
        try await waitUntil { store.connection == .failed }
        store.stop()
    }

    @Test func aLostConnectionFailsAfterTheDeadlineAndStaysFailedThroughFurtherDrops() async throws {
        let backend = ReconnectingTestBackend()
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        store.start()
        backend.emit(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.connection == .connected && clock.pendingSleepers == 0 }

        backend.emit(.disconnected(reason: "socket closed"))
        try await waitUntil { store.connection == .reconnecting && clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(15))
        try await waitUntil { store.connection == .failed }

        // The backend's next failed dial does not bring "Connecting…" back.
        backend.emit(.disconnected(reason: "dial failed"))
        await Task.yield()
        await Task.yield()
        #expect(store.connection == .failed)
        store.stop()
    }

    @Test func aKeptTranscriptStaysWhenTheConnectionFails() async throws {
        let cache = ConversationTranscriptCache(directory: FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID().uuidString)"))
        defer { cache.removeAll() }
        let backend = ReconnectingTestBackend()
        let kept = (1...3).map {
            ConversationMessage(id: "m\($0)", seq: $0, clientMessageID: nil, senderID: "lc",
                                sentAt: Date(timeIntervalSince1970: TimeInterval($0 * 60)), text: "message \($0)")
        }
        cache.save("chief", info: backend.info, meID: "me", messages: kept)
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        store.useTranscriptCache(cache, key: "chief")
        #expect(store.isShowingKeptTranscript)
        store.start()
        try await waitUntil { clock.pendingSleepers == 1 }
        clock.advance(by: .seconds(15))
        try await waitUntil { store.connection == .failed }
        #expect(store.isShowingKeptTranscript)
        #expect(store.messages.compactMap(\.seq) == [1, 2, 3])
        store.stop()
    }

    @Test func stopCancelsTheDeadline() async throws {
        let backend = ReconnectingTestBackend()
        let clock = DeadlineTestClock()
        let store = Self.store(backend, clock: clock)
        store.start()
        try await waitUntil { clock.pendingSleepers == 1 }
        store.stop()
        try await waitUntil { clock.pendingSleepers == 0 }
        clock.advance(by: .seconds(15))
        await Task.yield()
        #expect(store.connection == .connecting)
    }
}

// MARK: - Test doubles

/// A backend that only connects when told to, and counts `reconnectNow()`.
// crash-allow: every mutable field is read and written only under `lock`.
final class ReconnectingTestBackend: ConversationReconnectingBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "chief", title: "Chief", kind: .direct, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Chief", initials: "C", colorHex: "#30B0C7", isMe: false),
    ])
    private let lock = NSLock()
    private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
    private var reconnectCount = 0

    var reconnects: Int { lock.withLock { reconnectCount } }

    func events() -> AsyncStream<ConversationBackendEvent> {
        AsyncStream { continuation in lock.withLock { self.continuation = continuation } }
    }

    func emit(_ event: ConversationBackendEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    func reconnectNow() { lock.withLock { reconnectCount += 1 } }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: [], hasMore: false)
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "offline")
    }

    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "offline")
    }

    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "offline")
    }

    func unsend(messageID: String) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "offline")
    }

    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}

    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        throw ConversationBackendError(code: -1, message: "offline")
    }

    func close() { lock.withLock { continuation?.finish() } }
}

/// A clock that moves only when a test calls `advance(by:)`; a cancelled
/// sleeper throws at once and leaves `pendingSleepers`.
final class DeadlineTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var now: Instant { state.withLockUnchecked { $0.now } }
    var minimumResolution: Duration { .zero }
    var pendingSleepers: Int { state.withLockUnchecked { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLockUnchecked { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waits = state.withLockUnchecked { state -> Bool in
                    if deadline <= state.now || Task.isCancelled { return false }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                guard !waits else { return }
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLockUnchecked { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLockUnchecked { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}
