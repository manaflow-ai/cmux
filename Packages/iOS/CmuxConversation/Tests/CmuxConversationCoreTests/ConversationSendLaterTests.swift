import Foundation
import Testing
@testable import CmuxConversationCore

@MainActor
@Suite struct ConversationSendLaterTests {
    private func connectedStore(_ backend: SendLaterBackend) async throws -> ConversationStore {
        let sequence = ClientIDSequence(prefix: "c")
        let store = ConversationStore(backend: backend, pageSize: 30, clock: ImmediateClock(), makeClientMessageID: { sequence.next() })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        return store
    }

    @Test func scheduledRowSitsBelowLiveTrafficAndKeepsIdentityWhenSent() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        let at = Date().addingTimeInterval(3600)
        let rowID = try #require(store.scheduleSend(text: "later", at: at))
        #expect(store.messages.last?.rowID == rowID)
        #expect(store.messages.last?.isScheduled == true)
        #expect(store.messages.last?.delivery == .sending)
        try await waitUntil { store.messages.last?.id == "sched-c-1" }
        #expect(store.messages.last?.delivery == .sent)

        // Live traffic lands above the scheduled row.
        store.apply(.message(backend.makeMessage(seq: 6, sender: "lc"), eventSeq: 10))
        #expect(store.messages.map(\.id).suffix(2) == ["m6", "sched-c-1"])

        // The server sends it: the same row becomes the sent message, at the bottom.
        var sent = backend.makeMessage(seq: 7, sender: "me")
        sent.clientMessageID = "c-1"
        sent.text = "later"
        sent.delivery = .sent
        store.apply(.message(sent, eventSeq: 11))
        store.apply(.scheduledRemoved(id: "sched-c-1", clientMessageID: "c-1", eventSeq: 12))
        #expect(store.messages.last?.rowID == rowID)
        #expect(store.messages.last?.id == "m7")
        #expect(store.messages.last?.isScheduled == false)
        #expect(store.messages.last?.scheduledAt == nil)
        #expect(store.messages.filter { $0.clientMessageID == "c-1" }.count == 1)

        // A stale scheduled snapshot cannot resurrect the outlined row.
        var stale = try #require(backend.scheduledSnapshot(clientID: "c-1"))
        stale.delivery = .sent
        store.apply(.message(stale, eventSeq: 13))
        #expect(store.scheduledMessages.isEmpty)
    }

    @Test func scheduledRowsOrderByTimeAndRunPlanIgnoresThem() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        store.scheduleSend(text: "second", at: Date().addingTimeInterval(7200))
        store.scheduleSend(text: "first", at: Date().addingTimeInterval(3600))
        #expect(store.scheduledMessages.map(\.text) == ["first", "second"])
        let plan = ConversationRunPlan(messages: store.messages, meID: "me")
        let tail = plan.entries.suffix(2)
        #expect(tail.allSatisfy { $0.isFirstInRun && $0.isLastInRun && !$0.showsTimestamp && $0.status == .none })
        // The newest real message closes its run as if nothing followed.
        #expect(plan.entries[store.messages.count - 3].isLastInRun)
    }

    @Test func cancelRemovesAndServerRefusalRestores() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        var failures: [ConversationScheduledActionFailure] = []
        store.onScheduledActionFailed = { failures.append($0) }
        let rowID = try #require(store.scheduleSend(text: "x", at: Date().addingTimeInterval(600)))
        try await waitUntil { store.message(rowID: rowID)?.id == "sched-c-1" }

        backend.failNextAction = true
        store.cancelScheduled(rowID: rowID)
        #expect(store.message(rowID: rowID) == nil)
        try await waitUntil { store.message(rowID: rowID) != nil }
        #expect(failures == [.notCancelled])

        store.cancelScheduled(rowID: rowID)
        try await waitUntil { backend.cancelledIDs == ["sched-c-1"] }
        #expect(store.scheduledMessages.isEmpty)
        // The server's removal event after a local cancel is a no-op.
        store.apply(.scheduledRemoved(id: "sched-c-1", clientMessageID: "c-1", eventSeq: 20))
        #expect(store.scheduledMessages.isEmpty)
    }

    @Test func cancelBeforeTheUploadStartsNeverReachesTheServer() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        let rowID = try #require(store.scheduleSend(text: "x", at: Date().addingTimeInterval(600)))
        store.cancelScheduled(rowID: rowID)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.scheduledMessages.isEmpty)
        #expect(try await backend.scheduledMessages().isEmpty)
    }

    @Test func cancelBeforeTheScheduleAckCancelsOnTheServer() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        backend.holdSchedule = true
        let rowID = try #require(store.scheduleSend(text: "x", at: Date().addingTimeInterval(600)))
        try await waitUntil { backend.waitingScheduleCount == 1 }
        store.cancelScheduled(rowID: rowID)
        backend.releaseSchedule()
        try await waitUntil { backend.cancelledIDs == ["sched-c-1"] }
        #expect(store.scheduledMessages.isEmpty)
    }

    @Test func editTimeMovesTheRowAndRefusalRevertsIt() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        var failures: [ConversationScheduledActionFailure] = []
        store.onScheduledActionFailed = { failures.append($0) }
        let early = Date().addingTimeInterval(600)
        let late = Date().addingTimeInterval(1200)
        let a = try #require(store.scheduleSend(text: "a", at: early))
        store.scheduleSend(text: "b", at: late)
        try await waitUntil { store.scheduledMessages.allSatisfy { !$0.id.hasPrefix("local:") } }

        let later = Date().addingTimeInterval(1800)
        store.reschedule(rowID: a, to: later)
        #expect(store.scheduledMessages.map(\.text) == ["b", "a"])
        try await waitUntil { backend.rescheduled.count == 1 }

        backend.failNextAction = true
        store.reschedule(rowID: a, to: early.addingTimeInterval(-300))
        #expect(store.scheduledMessages.map(\.text) == ["a", "b"])
        try await waitUntil { failures == [.notEdited] }
        #expect(store.scheduledMessages.map(\.text) == ["b", "a"])
        #expect(abs((store.message(rowID: a)?.scheduledAt ?? .distantPast).timeIntervalSince(later)) < 0.01)
    }

    @Test func sendNowTurnsTheRowIntoASentMessage() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        let rowID = try #require(store.scheduleSend(text: "now", at: Date().addingTimeInterval(600)))
        try await waitUntil { store.message(rowID: rowID)?.id == "sched-c-1" }
        store.sendScheduledNow(rowID: rowID)
        #expect(store.message(rowID: rowID)?.delivery == .sending)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(store.message(rowID: rowID)?.isScheduled == false)
        #expect(store.messages.last?.rowID == rowID)
    }

    @Test func failedScheduleShowsWillNotSendAndTryAgainSendsWhenPastDue() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        let rowID = try #require(store.scheduleSend(text: "f", at: Date().addingTimeInterval(600)))
        try await waitUntil { store.message(rowID: rowID)?.id == "sched-c-1" }

        // The server reports it will not send (its time came and went).
        var failed = try #require(store.message(rowID: rowID))
        failed.delivery = .failed("not delivered")
        failed.scheduledAt = Date().addingTimeInterval(-5)
        store.apply(.message(failed, eventSeq: 30))
        #expect(store.message(rowID: rowID)?.delivery?.isFailed == true)
        #expect(store.message(rowID: rowID)?.isScheduled == true)
        let plan = ConversationRunPlan(messages: store.messages, meID: "me")
        #expect(plan.entries.last?.status == .notDelivered)

        // retry() routes a scheduled row to Try Again, never a plain send.
        store.retry(rowID: rowID)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(backend.sentNowIDs == ["sched-c-1"])
        #expect(backend.plainSendCount == 0)
    }

    @Test func scheduleFailureKeepsTheRowAsWillNotSend() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        backend.failNextSchedule = true
        let rowID = try #require(store.scheduleSend(text: "f", at: Date().addingTimeInterval(600)))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        #expect(store.message(rowID: rowID)?.isScheduled == true)
        store.retryScheduled(rowID: rowID)
        try await waitUntil { store.message(rowID: rowID)?.id == "sched-c-1" }
        #expect(store.message(rowID: rowID)?.delivery == .sent)
    }

    @Test func reconnectReloadsTheQueue() async throws {
        let backend = SendLaterBackend(total: 5)
        let store = try await connectedStore(backend)
        let rowID = try #require(store.scheduleSend(text: "x", at: Date().addingTimeInterval(600)))
        try await waitUntil { store.message(rowID: rowID)?.id == "sched-c-1" }
        // Cancelled from another device while this one was offline.
        backend.dropScheduled(id: "sched-c-1")
        backend.injectScheduled(text: "from phone", at: Date().addingTimeInterval(900))
        store.apply(.disconnected(reason: "test"))
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.scheduledMessages.map(\.text) == ["from phone"] }
    }

    @Test func defaultTimeIsAWholeHourOrNineTheNextMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ h: Int, _ m: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: h, minute: m))!
        }
        let afternoon = ConversationStore.defaultSendLaterDate(now: date(14, 10), calendar: calendar)
        #expect(afternoon == date(15, 0))
        let lateAfternoon = ConversationStore.defaultSendLaterDate(now: date(14, 40), calendar: calendar)
        #expect(lateAfternoon == date(16, 0))
        let night = ConversationStore.defaultSendLaterDate(now: date(22, 5), calendar: calendar)
        #expect(night == calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9)))
        let earlyMorning = ConversationStore.defaultSendLaterDate(now: date(3, 0), calendar: calendar)
        #expect(earlyMorning == date(9, 0))
    }
}

/// An in-memory backend with a Send Later queue.
final class SendLaterBackend: ConversationBackend, @unchecked Sendable {
    let base: ScriptedBackend
    var info: ConversationInfo { base.info }
    private let lock = NSLock()
    private var queue: [String: ConversationMessage] = [:]
    private var _cancelledIDs: [String] = []
    private var _rescheduled: [String] = []
    private var _sentNowIDs: [String] = []
    private var _failNextAction = false
    private var _failNextSchedule = false
    private var _holdSchedule = false
    private var scheduleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextSeq: Int
    private var _plainSendCount = 0

    init(total: Int) {
        base = ScriptedBackend(total: total)
        nextSeq = total + 1
    }

    var cancelledIDs: [String] { lock.withLock { _cancelledIDs } }
    var waitingScheduleCount: Int { lock.withLock { scheduleWaiters.count } }
    var rescheduled: [String] { lock.withLock { _rescheduled } }
    var sentNowIDs: [String] { lock.withLock { _sentNowIDs } }
    var plainSendCount: Int { lock.withLock { _plainSendCount } }
    var failNextAction: Bool { get { lock.withLock { _failNextAction } } set { lock.withLock { _failNextAction = newValue } } }
    var failNextSchedule: Bool { get { lock.withLock { _failNextSchedule } } set { lock.withLock { _failNextSchedule = newValue } } }
    var holdSchedule: Bool { get { lock.withLock { _holdSchedule } } set { lock.withLock { _holdSchedule = newValue } } }

    func releaseSchedule() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdSchedule = false
            defer { scheduleWaiters = [] }
            return scheduleWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func makeMessage(seq: Int, sender: String) -> ConversationMessage { base.makeMessage(seq: seq, sender: sender) }
    func scheduledSnapshot(clientID: String) -> ConversationMessage? {
        ConversationMessage(id: "sched-\(clientID)", seq: nil, clientMessageID: clientID, senderID: "me", sentAt: Date(), text: "later", scheduledAt: Date().addingTimeInterval(60))
    }
    func dropScheduled(id: String) { _ = lock.withLock { queue.removeValue(forKey: id) } }
    func injectScheduled(text: String, at date: Date) {
        lock.withLock {
            queue["sched-ext"] = ConversationMessage(id: "sched-ext", seq: nil, clientMessageID: "ext", senderID: "me", sentAt: Date(), text: text, delivery: .sent, scheduledAt: date)
        }
    }

    private func takeFailure() -> Bool {
        lock.withLock { defer { _failNextAction = false }; return _failNextAction }
    }

    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { _ in } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage { try await base.history(beforeSeq: beforeSeq, limit: limit) }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        lock.withLock { _plainSendCount += 1 }
        return try await base.send(draft)
    }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { try await base.react(messageID: messageID, reaction: reaction) }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { try await base.edit(messageID: messageID, text: text) }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { try await base.uploadImage(data, mimeType: mimeType) }
    func close() {}

    func scheduledMessages() async throws -> [ConversationMessage] {
        lock.withLock { queue.values.sorted { $0.scheduledAt! < $1.scheduledAt! } }
    }

    func scheduleSend(_ draft: ConversationOutgoingDraft, at date: Date) async throws -> ConversationMessage {
        if lock.withLock({ _holdSchedule }) {
            await withCheckedContinuation { waiter in
                let resumeNow = lock.withLock { () -> Bool in
                    guard _holdSchedule else { return true }
                    scheduleWaiters.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        let fail = lock.withLock { defer { _failNextSchedule = false }; return _failNextSchedule }
        if fail { throw ConversationBackendError(code: -32002, message: "not delivered") }
        let message = ConversationMessage(
            id: "sched-\(draft.clientMessageID)", seq: nil, clientMessageID: draft.clientMessageID, senderID: "me",
            sentAt: Date(), text: draft.text, replyToID: draft.replyToID, delivery: .sent, scheduledAt: date
        )
        lock.withLock { queue[message.id] = message }
        return message
    }

    func reschedule(scheduledID: String, to date: Date) async throws -> ConversationMessage {
        if takeFailure() { throw ConversationBackendError(code: -32002, message: "not delivered") }
        return try lock.withLock {
            guard var message = queue[scheduledID] else { throw ConversationBackendError(code: -32602, message: "unknown id") }
            message.scheduledAt = date
            message.delivery = .sent
            queue[scheduledID] = message
            _rescheduled.append(scheduledID)
            return message
        }
    }

    func cancelScheduled(scheduledID: String) async throws {
        if takeFailure() { throw ConversationBackendError(code: -32002, message: "not delivered") }
        lock.withLock {
            queue[scheduledID] = nil
            _cancelledIDs.append(scheduledID)
        }
    }

    func sendScheduledNow(scheduledID: String) async throws -> ConversationMessage {
        try lock.withLock {
            guard let scheduled = queue.removeValue(forKey: scheduledID) else { throw ConversationBackendError(code: -32602, message: "unknown id") }
            _sentNowIDs.append(scheduledID)
            let seq = nextSeq
            nextSeq += 1
            return ConversationMessage(
                id: "m\(seq)", seq: seq, clientMessageID: scheduled.clientMessageID, senderID: "me",
                sentAt: Date(), text: scheduled.text, delivery: .sent
            )
        }
    }
}
