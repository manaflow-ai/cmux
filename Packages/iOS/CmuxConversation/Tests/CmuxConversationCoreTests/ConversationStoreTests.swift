import Foundation
import Testing
@testable import CmuxConversationCore

@MainActor
@Suite struct ConversationStoreTests {
    @Test func newestPageThenOlderPagePrependsContiguousHistory() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.messages.compactMap(\.seq) == Array(71...100))
        #expect(store.older == .idle)

        store.loadOlder()
        #expect(store.older == .loading)
        try await waitUntil { store.messages.count == 60 }
        #expect(store.messages.compactMap(\.seq) == Array(41...100))
        #expect(changes.contains(.prepended))
    }

    @Test func defaultPagesMatchMessagesLoadMoreCount() async throws {
        // Messages loads history 50 messages at a time on iPhone.
        let backend = ScriptedBackend(total: 200)
        let store = ConversationStore(backend: backend)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.messages.compactMap(\.seq) == Array(151...200))
        store.loadOlder()
        try await waitUntil { store.messages.count == 100 }
        #expect(store.messages.first?.seq == 101)
    }

    @Test func olderFetchFailureRetriesThenSucceeds() async throws {
        let backend = ScriptedBackend(total: 100)
        backend.failNextHistory = 2
        let store = ConversationStore(backend: backend, pageSize: 30, clock: ImmediateClock())
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextHistory = 2
        store.loadOlder()
        try await waitUntil { store.messages.count == 60 }
        #expect(store.older == .idle)
    }

    @Test func historyExhaustsAtTheFirstMessage() async throws {
        let backend = ScriptedBackend(total: 45)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.loadOlder()
        try await waitUntil { store.older == .exhausted }
        #expect(store.messages.compactMap(\.seq) == Array(1...45))
    }

    @Test func duplicateAndStaleEventsAreIgnored() async throws {
        let backend = ScriptedBackend(total: 10)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let live = backend.makeMessage(seq: 11, sender: "lc")
        store.apply(.message(live, eventSeq: 500))
        store.apply(.message(live, eventSeq: 500))
        var stale = live
        stale.text = "stale"
        store.apply(.message(stale, eventSeq: 499))
        #expect(store.messages.count == 11)
        #expect(store.messages.last?.text == live.text)
    }

    @Test func optimisticSendKeepsRowIdentityThroughAckAndDeliveryNeverRegresses() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.holdSend = true
        let rowID = try #require(store.send(text: "hello"))
        #expect(store.messages.last?.rowID == rowID)
        #expect(store.messages.last?.delivery == .sending)

        // The live echo (delivered) races ahead of the ack (sent).
        var echo = backend.makeMessage(seq: 6, sender: "me")
        echo.clientMessageID = "client-1"
        echo.text = "hello"
        echo.delivery = .delivered
        store.apply(.message(echo, eventSeq: 900))
        backend.releaseSend()
        try await waitUntil { backend.sendCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.messages.filter { $0.rowID == rowID }.count == 1)
        #expect(store.messages.count == 6)
        #expect(store.messages.last?.delivery == .delivered)
    }

    @Test func sendWithEffectCarriesTheEffectOnTheRowAndTheDraft() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "fx-1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let rowID = try #require(store.send(text: "boom", effect: .slam))
        #expect(store.message(rowID: rowID)?.effect == .slam)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(backend.sentEffects == [.slam])
        #expect(store.message(rowID: rowID)?.effect == .slam)
        store.send(text: "plain")
        try await waitUntil { backend.sendCount == 2 }
        #expect(backend.sentEffects == [.slam, nil])
    }

    @Test func effectKindsSplitBubbleAndScreen() {
        #expect(ConversationMessageEffect.bubbleEffects.allSatisfy { $0.kind == .bubble })
        #expect(ConversationMessageEffect.screenEffects.allSatisfy { $0.kind == .screen })
        #expect(Set(ConversationMessageEffect.bubbleEffects + ConversationMessageEffect.screenEffects) == Set(ConversationMessageEffect.allCases))
    }

    @Test func wireDecodingReadsEffectAndIgnoresUnknownOnes() throws {
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        let known = WireDecoding.message(["id": "m1", "senderId": "lc", "text": "hi", "effect": "invisibleInk"], base: base)
        #expect(known?.effect == .invisibleInk)
        let unknown = WireDecoding.message(["id": "m2", "senderId": "lc", "text": "hi", "effect": "sparkle"], base: base)
        #expect(unknown != nil && unknown?.effect == nil)
    }

    @Test func rapidSendsReachTheBackendOneAtATimeInSendOrder() async throws {
        let backend = ScriptedBackend(total: 5)
        let ids = ClientIDSequence(prefix: "rapid")
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { ids.next() })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.holdSend = true
        store.send(text: "one")
        store.send(text: "two")
        store.send(text: "three")
        try await Task.sleep(for: .milliseconds(50))
        // The server numbers messages in arrival order, so a later send must not
        // be dispatched while an earlier one is still in flight.
        #expect(backend.sentClientIDs == ["rapid-1"])
        backend.releaseSend()
        try await waitUntil { backend.sendCount == 3 }
        #expect(backend.sentClientIDs == ["rapid-1", "rapid-2", "rapid-3"])
    }

    @Test func aFailedSendStaysBelowMyEarlierSendsAckedLater() async throws {
        let backend = ScriptedBackend(total: 5)
        backend.stampAcksWithServerNow = true
        let ids = ClientIDSequence(prefix: "order")
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { ids.next() })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.holdSend = true
        store.send(text: "first")
        let secondRow = try #require(store.send(text: "second"))
        try await waitUntil { backend.sentClientIDs == ["order-1"] }
        backend.failNextSend = true
        backend.releaseSend()
        try await waitUntil { store.message(rowID: secondRow)?.delivery?.isFailed == true }
        // A later arrival re-sorts the transcript. The server stamped "first"
        // after "second" was composed locally; the failed send must still read
        // after it, in the order they were sent, with the arrival below both.
        var arrival = backend.makeMessage(seq: 7, sender: "lc")
        arrival.sentAt = Date().addingTimeInterval(10)
        store.apply(.message(arrival, eventSeq: 901))
        let texts = store.messages.suffix(3).map(\.text)
        #expect(texts == ["first", "second", "message 7"])
    }

    @Test func failedSendStaysVisibleAndRetryReusesClientID() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-2" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "will fail"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        store.retry(rowID: rowID)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(backend.sentClientIDs == ["client-2", "client-2"])
    }

    @Test func laggedReconnectMergesMissingPagesAndKeepsPendingSends() async throws {
        let backend = ScriptedBackend(total: 50)
        let store = ConversationStore(backend: backend, pageSize: 20, makeClientMessageID: { "client-3" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.holdSend = true
        store.send(text: "in flight")
        backend.total = 80
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { store.message(id: "m80") != nil }
        #expect(store.messages.compactMap(\.seq) == Array(31...80))
        #expect(store.messages.last?.clientMessageID == "client-3")
        backend.releaseSend()
    }

    /// A restarted backend's history no longer holds the kept window: the
    /// client holds 81-100 and the server now has 1-50. Recovery rebuilds from
    /// the fetched page (keeping an unsent local send), and new live messages
    /// 51-80, during the fetch and after it, land instead of being dropped as
    /// older than the stale window.
    @Test func laggedReconnectAfterABackendResetRebuildsFromTheFetchedHistory() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 20, makeClientMessageID: { "client-4" })
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.messages.compactMap(\.seq) == Array(81...100))
        backend.holdSend = true
        defer { backend.releaseSend() }
        store.send(text: "in flight")
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        backend.total = 50
        let historyBefore = backend.historyCount
        var rebuilt = false
        store.addObserver { change in
            if case .reset = change { rebuilt = true }
        }
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == historyBefore + 1 }
        // Live traffic from the restarted backend while its history is held.
        store.apply(.message(backend.makeMessage(seq: 51, sender: "lc"), eventSeq: 1))
        gate.open()
        try await waitUntil { rebuilt }
        #expect(store.messages.compactMap(\.seq) == Array(31...51))
        #expect(store.messages.last?.clientMessageID == "client-4")
        #expect(store.older == .idle)
        for seq in 52...80 {
            store.apply(.message(backend.makeMessage(seq: seq, sender: "lc"), eventSeq: seq - 50))
        }
        #expect(store.messages.compactMap(\.seq) == Array(31...80))
        #expect(store.message(id: "m100") == nil)
        #expect(store.messages.last?.clientMessageID == "client-4")
    }

    @Test func reconnectDuringCatchUpDoesNotSkipTheGapBeforeALiveArrival() async throws {
        let backend = ScriptedBackend(total: 50)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        backend.total = 100
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }
        // New live traffic is visible while history is held. A second
        // reconnect must not mistake that isolated row for a complete tail.
        store.apply(.message(backend.makeMessage(seq: 100, sender: "lc"), eventSeq: 1))
        var merged = false
        store.addObserver { change in
            if case .live = change { merged = true }
        }
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { merged }
        #expect(store.messages.compactMap(\.seq) == Array(31...100))
    }

    @Test func reconnectAfterEmptyHistoryRestoresOlderPaging() async throws {
        let backend = ScriptedBackend(total: 0)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.older == .exhausted)
        backend.total = 80
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { store.message(id: "m80") != nil }
        #expect(store.older == .idle)
        store.loadOlder()
        try await waitUntil { store.message(id: "m41") != nil }
        #expect(store.messages.compactMap(\.seq) == Array(41...80))
    }

    @Test(arguments: [20, 200])
    func interruptedRecoveryAfterEmptyHistoryKeepsOlderMessagesReachable(pageSize: Int) async throws {
        let backend = ScriptedBackend(total: 0)
        let store = ConversationStore(backend: backend, pageSize: pageSize)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.older == .exhausted)
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        backend.total = 100
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }
        store.apply(.message(backend.makeMessage(seq: 100, sender: "lc"), eventSeq: 1))
        var merged = false
        store.addObserver { change in
            if case .live = change { merged = true }
        }
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { merged }
        #expect(store.older == .idle)
        // Recovery retains the live row as the window's anchor, but the
        // filtered overlap rows and every earlier page must remain reachable.
        for page in 1...((99 + pageSize - 1) / pageSize) {
            let oldest = max(1, 100 - page * pageSize)
            store.loadOlder()
            try await waitUntil { store.messages.first?.seq == oldest }
        }
        #expect(store.messages.compactMap(\.seq) == Array(1...100))
        #expect(store.older == .exhausted)
    }

    @Test func liveRowOlderThanTheFetchedPageDuringEmptyRecoveryLeavesNoGap() async throws {
        let backend = ScriptedBackend(total: 0)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        backend.total = 100
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }
        // An update for message 50 arrives while the newest page (81-100) is
        // held. Recovery must fetch down to it, not leave 51-80 unreachable.
        store.apply(.message(backend.makeMessage(seq: 50, sender: "lc"), eventSeq: 1))
        gate.open()
        try await waitUntil { store.message(id: "m100") != nil }
        #expect(store.messages.compactMap(\.seq) == Array(50...100))
        #expect(store.older == .idle)
        for oldest in [30, 10, 1] {
            store.loadOlder()
            try await waitUntil { store.messages.first?.seq == oldest }
        }
        #expect(store.messages.compactMap(\.seq) == Array(1...100))
    }

    /// An older page asked for before a lagged reconnect carries what the
    /// server had then. Whether it lands while recovery is fetching or after
    /// recovery applied (recovery leaves rows above its window to the pager),
    /// it must never bring back a message unsent while disconnected.
    @Test(arguments: [false, true])
    func olderPageAskedBeforeReconnectNeverLandsStaleRows(landsAfterRecovery: Bool) async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        // An older page (61-80) is asked for and held with its pre-disconnect contents.
        let older = PreparationGate()
        defer { older.open() }
        backend.nextHistoryGate = older
        store.loadOlder()
        try await waitUntil { backend.historyCount == 2 }
        // Message 70 was unsent while disconnected.
        var unsent = backend.makeMessage(seq: 70, sender: "lc")
        unsent.text = ""
        unsent.unsentAt = Date(timeIntervalSince1970: 1_800_000_000)
        backend.setHistoryMessage(unsent)
        backend.total = 101
        let newest = PreparationGate()
        defer { newest.open() }
        if !landsAfterRecovery { backend.nextHistoryGate = newest }
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        if landsAfterRecovery {
            try await waitUntil { store.message(id: "m101") != nil }
            older.open()
        } else {
            try await waitUntil { backend.historyCount == 3 }
            older.open()
            // Let the stale reply reach the store before recovery's does.
            try await Task.sleep(for: .milliseconds(50))
            newest.open()
            try await waitUntil { store.message(id: "m101") != nil }
        }
        try await waitUntil { store.message(id: "m61") != nil }
        #expect(store.message(id: "m70")?.unsentAt == unsent.unsentAt)
        #expect(store.message(id: "m70")?.text == "")
        #expect(store.messages.compactMap(\.seq) == Array(61...101))
    }

    /// The catch-up jump fetches older pages itself; one asked for before a
    /// lagged reconnect must not bring back a message unsent meanwhile either.
    @Test func catchUpPageAskedBeforeReconnectNeverLandsStaleRows() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let older = PreparationGate()
        defer { older.open() }
        backend.nextHistoryGate = older
        let loaded = Task { await store.loadThrough(seq: 70) }
        try await waitUntil { backend.historyCount == 2 }
        var unsent = backend.makeMessage(seq: 70, sender: "lc")
        unsent.text = ""
        unsent.unsentAt = Date(timeIntervalSince1970: 1_800_000_000)
        backend.setHistoryMessage(unsent)
        backend.total = 101
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { store.message(id: "m101") != nil }
        older.open()
        #expect(await loaded.value)
        #expect(store.message(id: "m70")?.unsentAt == unsent.unsentAt)
        #expect(store.message(id: "m70")?.text == "")
        #expect(store.messages.compactMap(\.seq) == Array(61...101))
    }

    /// A vote or an added choice made while recovery fetches is local intent
    /// over the poll, not a newer revision of the message: the recovered edit
    /// and other people's votes still apply, the intent stays on top, and a
    /// refusal rolls back to the recovered poll, not the pre-disconnect one.
    @Test(arguments: [false, true])
    func reconnectAppliesAuthoritativeChangeAfterAPendingPollAction(addsChoice: Bool) async throws {
        let backend = ScriptedBackend(total: 30)
        var original = backend.makeMessage(seq: 25, sender: "lc")
        original.text = "Lunch?"
        original.poll = ConversationPoll(question: "Lunch?", options: [
            ConversationPollOption(id: "a", text: "Tacos"),
            ConversationPollOption(id: "b", text: "Ramen"),
        ])
        backend.setHistoryMessage(original)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        // While disconnected the question was edited and someone voted.
        var changed = original
        changed.text = "Lunch on Friday?"
        changed.poll?.setVote(participantID: "aw", optionID: "a", selected: true)
        backend.setHistoryMessage(changed)
        backend.total = 31
        let history = PreparationGate()
        defer { history.open() }
        backend.nextHistoryGate = history
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        // My poll action is held, then refused.
        let action = PreparationGate()
        defer { action.open() }
        backend.localActionGate = action
        if addsChoice {
            store.addPollChoice(messageID: "m25", text: "Pho")
        } else {
            store.togglePollVote(messageID: "m25", optionID: "b")
        }
        history.open()
        try await waitUntil { store.message(id: "m31") != nil }
        let recovered = try #require(store.message(id: "m25"))
        #expect(recovered.text == changed.text)
        #expect(recovered.poll?.hasVote(participantID: "aw", optionID: "a") == true)
        if addsChoice {
            #expect(recovered.poll?.options.map(\.text) == ["Tacos", "Ramen", "Pho"])
        } else {
            #expect(recovered.poll?.hasVote(participantID: "me", optionID: "b") == true)
        }
        action.open()
        try await waitUntil { store.message(id: "m25")?.poll == changed.poll }
        #expect(store.message(id: "m25")?.text == changed.text)
    }

    /// My edit made while recovery fetches is local intent over the row: the
    /// recovered revision still applies under it, and a refusal rolls back to
    /// that recovered revision, not the copy from before the disconnect.
    @Test(arguments: [false, true])
    func editDuringRecoveryRollsBackToTheRecoveredRevision(unsentElsewhere: Bool) async throws {
        let backend = ScriptedBackend(total: 30)
        var original = backend.makeMessage(seq: 25, sender: "me")
        original.sentAt = Date()
        original.text = "Original"
        backend.setHistoryMessage(original)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        // While disconnected my other device edited or unsent it.
        var changed = original
        if unsentElsewhere {
            changed.text = ""
            changed.unsentAt = Date()
        } else {
            changed.text = "Edited elsewhere"
            changed.editedAt = Date()
            changed.editCount = 1
        }
        backend.setHistoryMessage(changed)
        backend.total = 31
        let history = PreparationGate()
        defer { history.open() }
        backend.nextHistoryGate = history
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        let action = PreparationGate()
        defer { action.open() }
        backend.localActionGate = action
        store.edit(messageID: "m25", text: "Edited here")
        #expect(store.message(id: "m25")?.text == "Edited here")
        history.open()
        try await waitUntil { store.message(id: "m31") != nil }
        if unsentElsewhere {
            #expect(store.message(id: "m25")?.unsentAt == changed.unsentAt)
            #expect(store.message(id: "m25")?.text == "")
        } else {
            // My edit is still in flight: it stays on top of the recovered row.
            #expect(store.message(id: "m25")?.text == "Edited here")
        }
        action.open()
        try await waitUntil { store.message(id: "m25")?.text == changed.text }
        let result = try #require(store.message(id: "m25"))
        #expect(result.unsentAt == changed.unsentAt)
        #expect(result.editCount == changed.editCount)
    }

    enum PendingLocalAction: CaseIterable, Sendable { case react, vote, edit, unsend }

    /// Whatever local action is in flight (a reaction, a poll vote, an edit,
    /// an unsend), it holds back only the fields it changes: the recovered
    /// revision's other fields apply, during the action and after a refusal.
    @Test(arguments: PendingLocalAction.allCases)
    func aPendingLocalActionHoldsBackOnlyItsOwnFields(action pending: PendingLocalAction) async throws {
        let backend = ScriptedBackend(total: 30)
        var original = backend.makeMessage(seq: 25, sender: "me")
        original.sentAt = Date()
        if pending == .vote {
            original.poll = ConversationPoll(question: "Lunch?", options: [
                ConversationPollOption(id: "a", text: "Tacos"),
                ConversationPollOption(id: "b", text: "Ramen"),
            ])
        }
        backend.setHistoryMessage(original)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        // While disconnected, two replies arrived in its thread.
        var changed = original
        changed.replyCount = 2
        backend.setHistoryMessage(changed)
        backend.total = 31
        let history = PreparationGate()
        defer { history.open() }
        backend.nextHistoryGate = history
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        let action = PreparationGate()
        defer { action.open() }
        backend.localActionGate = action
        switch pending {
        case .react: store.react(messageID: "m25", reaction: .heart)
        case .vote: store.togglePollVote(messageID: "m25", optionID: "a")
        case .edit: store.edit(messageID: "m25", text: "Edited here")
        case .unsend: store.unsend(messageID: "m25")
        }
        history.open()
        try await waitUntil { store.message(id: "m31") != nil }
        #expect(store.message(id: "m25")?.replyCount == 2)
        switch pending {
        case .react: #expect(store.message(id: "m25")?.reactions.isEmpty == false)
        case .vote: #expect(store.message(id: "m25")?.poll?.hasVote(participantID: "me", optionID: "a") == true)
        case .edit: #expect(store.message(id: "m25")?.text == "Edited here")
        case .unsend: #expect(store.message(id: "m25")?.isUnsent == true)
        }
        action.open()
        switch pending {
        case .react: try await Task.sleep(for: .milliseconds(50))
        case .vote: try await waitUntil { store.message(id: "m25")?.poll == changed.poll }
        case .edit: try await waitUntil { store.message(id: "m25")?.text == changed.text }
        case .unsend: try await waitUntil { store.message(id: "m25")?.unsendFailed == true }
        }
        #expect(store.message(id: "m25")?.replyCount == 2)
    }

    /// A message that first arrives live while recovery fetches, then is
    /// edited or reacted to live, keeps that live state: a page fetched
    /// before those events carries an older copy of it.
    @Test(arguments: [false, true])
    func aRowThatArrivesLiveDuringRecoveryKeepsItsLiveState(reacted: Bool) async throws {
        let backend = ScriptedBackend(total: 30)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        // Message 31 was sent while disconnected; the held page carries it as sent.
        backend.total = 31
        let history = PreparationGate()
        defer { history.open() }
        backend.nextHistoryGate = history
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        // After the page was read, it arrives live and then changes live.
        store.apply(.message(backend.makeMessage(seq: 31, sender: "lc"), eventSeq: 1))
        var changed = backend.makeMessage(seq: 31, sender: "lc")
        if reacted {
            changed.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        } else {
            changed.text = "Edited live"
            changed.editedAt = Date()
            changed.editCount = 1
        }
        store.apply(.message(changed, eventSeq: 2))
        var merged = false
        store.addObserver { change in
            if case .live = change { merged = true }
        }
        history.open()
        // The merge notifies only after recovery applied in full.
        try await waitUntil { merged && backend.historyCount >= 2 }
        let result = try #require(store.message(id: "m31"))
        #expect(result.text == changed.text)
        #expect(result.editCount == changed.editCount)
        #expect(result.reactions == changed.reactions)
    }

    /// My reaction pending during recovery keeps only my own mark: reactions
    /// others added while I was disconnected come from the recovered copy.
    @Test func aPendingReactionKeepsOthersRecoveredReactions() async throws {
        let backend = ScriptedBackend(total: 30)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        var changed = backend.makeMessage(seq: 25, sender: "lc")
        changed.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        backend.setHistoryMessage(changed)
        backend.total = 31
        let history = PreparationGate()
        defer { history.open() }
        backend.nextHistoryGate = history
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        let action = PreparationGate()
        defer { action.open() }
        backend.localActionGate = action
        store.react(messageID: "m25", reaction: .heart)
        history.open()
        try await waitUntil { store.message(id: "m31") != nil }
        let reactions = try #require(store.message(id: "m25")?.reactions)
        #expect(Set(reactions) == [
            ConversationReactionMark(participantID: "aw", reaction: .haha),
            ConversationReactionMark(participantID: "me", reaction: .heart),
        ])
    }

    /// A delivery receipt is not a newer revision of the message: a live
    /// receipt during recovery keeps its delivery, and the recovered edit or
    /// unsend still applies.
    @Test(arguments: [false, true])
    func reconnectAppliesAuthoritativeChangeAfterALiveDeliveryReceipt(unsent: Bool) async throws {
        let backend = ScriptedBackend(total: 30)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        // My message 24 was edited or unsent while disconnected.
        var changed = backend.makeMessage(seq: 24, sender: "me")
        changed.text = unsent ? "" : "Edited while disconnected"
        if unsent { changed.unsentAt = Date(timeIntervalSince1970: 2000) }
        backend.setHistoryMessage(changed)
        backend.total = 31
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        // A read receipt for the copy still on screen arrives live.
        var receipt = backend.makeMessage(seq: 24, sender: "me")
        receipt.delivery = .read(nil)
        store.apply(.message(receipt, eventSeq: 1))
        #expect(store.message(id: "m24")?.delivery == .read(nil))
        gate.open()
        try await waitUntil { store.message(id: "m31") != nil }
        let result = try #require(store.message(id: "m24"))
        #expect(result.text == changed.text)
        #expect(result.unsentAt == changed.unsentAt)
        #expect(result.delivery == .read(nil))
    }

    @Test func reconnectRefreshesMissedEditsThroughoutRetainedHistory() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        for oldest in [61, 41, 21] {
            store.loadOlder()
            try await waitUntil { store.messages.first?.seq == oldest }
        }
        var edited = backend.makeMessage(seq: 25, sender: "lc")
        edited.text = "Edited while disconnected"
        backend.setHistoryMessage(edited)
        var unsent = backend.makeMessage(seq: 26, sender: "lc")
        unsent.text = ""
        unsent.unsentAt = Date(timeIntervalSince1970: 1_800_000_000)
        backend.setHistoryMessage(unsent)
        backend.total = 105
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { store.message(id: "m105") != nil }
        #expect(store.message(id: "m25")?.text == edited.text)
        #expect(store.message(id: "m26")?.unsentAt == unsent.unsentAt)
        // The overlap page must not load unseen history above the old window.
        #expect(store.messages.compactMap(\.seq) == Array(21...105))
    }

    @Test(arguments: [false, true])
    func reconnectAppliesAuthoritativeChangeAfterLocalPreviewLoads(unsent: Bool) async throws {
        let backend = ScriptedBackend(total: 30)
        let url = try #require(URL(string: "https://example.com/article"))
        var original = backend.makeMessage(seq: 25, sender: "lc")
        original.text = url.absoluteString
        original.linkPreview = ConversationLinkPreview(url: url, state: .tapToLoad)
        backend.setHistoryMessage(original)
        backend.linkPreviews[url] = ConversationLinkPreview(url: url, title: "Loaded locally")
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        var changed = original
        changed.text = unsent ? "" : "Updated article \(url.absoluteString)"
        if unsent {
            changed.unsentAt = Date(timeIntervalSince1970: 2000)
            changed.linkPreview = nil
        }
        backend.setHistoryMessage(changed)
        backend.total = 31
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        // Local presentation enrichment is not a newer server revision.
        // It must not suppress the edit/unsend in the held history reply.
        store.loadLinkPreview(messageID: "m25")
        try await waitUntil { store.message(id: "m25")?.linkPreview?.state == .loaded }
        gate.open()
        try await waitUntil { store.message(id: "m31") != nil }
        let result = try #require(store.message(id: "m25"))
        #expect(result.text == changed.text)
        #expect(result.unsentAt == changed.unsentAt)
        if !unsent {
            // The unchanged URL keeps the enriched card while server text wins.
            #expect(result.linkPreview?.title == "Loaded locally")
            #expect(result.linkPreview?.state == .loaded)
        }
    }

    @Test(arguments: [false, true])
    func reconnectAppliesAuthoritativeChangeAfterAFailedLocalReaction(unsent: Bool) async throws {
        let backend = ScriptedBackend(total: 30)
        let store = ConversationStore(backend: backend, pageSize: 20)
        defer { store.stop() }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        // Message 25 was edited or unsent while disconnected.
        var changed = backend.makeMessage(seq: 25, sender: "lc")
        changed.text = unsent ? "" : "Edited while disconnected"
        if unsent { changed.unsentAt = Date(timeIntervalSince1970: 2000) }
        backend.setHistoryMessage(changed)
        backend.total = 31
        let gate = PreparationGate()
        defer { gate.open() }
        backend.nextHistoryGate = gate
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { backend.historyCount == 2 }

        // Reacting to the still-visible copy is an optimistic local change,
        // and this backend refuses it. It must not hold back the recovered
        // edit or unsend.
        store.react(messageID: "m25", reaction: .heart)
        #expect(store.message(id: "m25")?.reactions.isEmpty == false)
        gate.open()
        try await waitUntil { store.message(id: "m31") != nil }
        let result = try #require(store.message(id: "m25"))
        #expect(result.text == changed.text)
        #expect(result.unsentAt == changed.unsentAt)
        if unsent { #expect(result.reactions.isEmpty) }
    }

    @Test func typingClearsWhenThatParticipantsMessageArrives() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.apply(.typing(participantID: "lc", isTyping: true))
        store.apply(.typing(participantID: "aw", isTyping: true))
        #expect(store.typingParticipantIDs == ["lc", "aw"])
        store.apply(.message(backend.makeMessage(seq: 6, sender: "lc"), eventSeq: 10))
        #expect(store.typingParticipantIDs == ["aw"])
    }

    @Test func typingStopFollowedByTheMessageReplacesTheIndicatorInOneChange() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.apply(.typing(participantID: "lc", isTyping: true))
        var changes: [ConversationStoreChange] = []
        store.addObserver { changes.append($0) }
        // Services clear typing just before the message itself is delivered.
        store.apply(.typing(participantID: "lc", isTyping: false))
        store.apply(.message(backend.makeMessage(seq: 6, sender: "lc"), eventSeq: 10))
        #expect(store.typingParticipantIDs.isEmpty)
        #expect(changes.contains(.typing) == false)
        #expect(changes.count == 1)
    }

    /// A live message applies only once the work its observer readied for
    /// it finished, one message at a time, in arrival order.
    @Test func liveMessagesApplyAfterTheirPreparationInOrder() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        let finished = PreparedIDs()
        var asked: [String] = []
        var appliedEarly: [String] = []
        store.prepareLiveMessage = { message in
            asked.append(message.id)
            return {
                await Task.yield()
                finished.insert(message.id)
            }
        }
        store.addObserver { _ in
            for message in store.messages where asked.contains(message.id) && !finished.contains(message.id) {
                appliedEarly.append(message.id)
            }
        }
        store.start()
        backend.emit(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.emit(.message(backend.makeMessage(seq: 6, sender: "lc"), eventSeq: 10))
        backend.emit(.message(backend.makeMessage(seq: 7, sender: "aw"), eventSeq: 11))
        try await waitUntil { store.messages.count == 7 }
        #expect(asked == ["m6", "m7"])
        #expect(finished.ids == ["m6", "m7"])
        #expect(appliedEarly.isEmpty)
        #expect(store.messages.suffix(2).map(\.id) == ["m6", "m7"])
    }

    /// A message still being readied when the store stops never applies.
    @Test func aMessageReadiedAfterStopIsDropped() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        let gate = PreparationGate()
        var asked = false
        store.prepareLiveMessage = { _ in
            asked = true
            return { await gate.wait() }
        }
        store.start()
        backend.emit(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.emit(.message(backend.makeMessage(seq: 6, sender: "lc"), eventSeq: 10))
        try await waitUntil { asked }
        store.stop()
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.message(id: "m6") == nil)
    }

    @Test func typingStopWithoutAMessageStillClears() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, clock: ImmediateClock())
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.apply(.typing(participantID: "lc", isTyping: true))
        store.apply(.typing(participantID: "lc", isTyping: false))
        try await waitUntil { store.typingParticipantIDs.isEmpty }
    }
}

// MARK: - Test doubles

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met before timeout")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await Task.yield()
    }
}

/// Holds whoever waits until opened.
final class PreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Message ids, recorded from any thread in order.
final class PreparedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func insert(_ id: String) { lock.withLock { _ids.append(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { _ids.contains(id) } }
}

final class ClientIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var count = 0
    init(prefix: String) { self.prefix = prefix }
    func next() -> String { lock.withLock { count += 1; return "\(prefix)-\(count)" } }
}

final class ScriptedBackend: ConversationBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
        ConversationParticipant(id: "aw", name: "Austin Wang", initials: "AW", colorHex: "#8E8E93", isMe: false),
    ])
    private let lock = NSLock()
    private var _total: Int
    private var _failNextHistory = 0
    private var _nextHistoryGate: PreparationGate?
    private var _historyCount = 0
    private var _historyMessages: [String: ConversationMessage] = [:]
    private var _localActionGate: PreparationGate?
    private var _failNextSend = false
    private var _holdSend = false
    private var _sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var _sentClientIDs: [String] = []
    private var _sentDrafts: [ConversationOutgoingDraft] = []
    private var _sentEffects: [ConversationMessageEffect?] = []
    private var _sendCount = 0
    private var _stampAcksWithServerNow = false

    init(total: Int) { _total = total }

    var total: Int { get { lock.withLock { _total } } set { lock.withLock { _total = newValue } } }
    var failNextHistory: Int { get { lock.withLock { _failNextHistory } } set { lock.withLock { _failNextHistory = newValue } } }
    var nextHistoryGate: PreparationGate? { get { lock.withLock { _nextHistoryGate } } set { lock.withLock { _nextHistoryGate = newValue } } }
    /// When set, a reaction, poll vote or choice, edit or unsend is held
    /// until it opens and then refused.
    var localActionGate: PreparationGate? { get { lock.withLock { _localActionGate } } set { lock.withLock { _localActionGate = newValue } } }
    private func refuseHeldLocalAction() async throws {
        guard let gate = localActionGate else { return }
        await gate.wait()
        throw ConversationBackendError(code: -1, message: "refused")
    }
    func votePoll(messageID: String, optionID: String, selected: Bool) async throws -> ConversationMessage {
        try await refuseHeldLocalAction()
        throw ConversationBackendError(code: -1, message: "vote refused")
    }
    func addPollOption(messageID: String, text: String) async throws -> ConversationMessage {
        try await refuseHeldLocalAction()
        throw ConversationBackendError(code: -1, message: "choice refused")
    }
    var historyCount: Int { lock.withLock { _historyCount } }
    func setHistoryMessage(_ message: ConversationMessage) {
        lock.withLock { _historyMessages[message.id] = message }
    }
    var failNextSend: Bool { get { lock.withLock { _failNextSend } } set { lock.withLock { _failNextSend = newValue } } }
    var holdSend: Bool { get { lock.withLock { _holdSend } } set { lock.withLock { _holdSend = newValue } } }
    var sentClientIDs: [String] { lock.withLock { _sentClientIDs } }
    var sentDrafts: [ConversationOutgoingDraft] { lock.withLock { _sentDrafts } }
    var sentEffects: [ConversationMessageEffect?] { lock.withLock { _sentEffects } }
    var sendCount: Int { lock.withLock { _sendCount } }
    /// Acks carry a server time later than any local send time, as a real server's do.
    var stampAcksWithServerNow: Bool { get { lock.withLock { _stampAcksWithServerNow } } set { lock.withLock { _stampAcksWithServerNow = newValue } } }

    func releaseSend() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdSend = false
            defer { _sendWaiters = [] }
            return _sendWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func makeMessage(seq: Int, sender: String) -> ConversationMessage {
        ConversationMessage(
            id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: sender,
            sentAt: Date(timeIntervalSince1970: TimeInterval(seq * 60)), text: "message \(seq)"
        )
    }

    private var _continuation: AsyncStream<ConversationBackendEvent>.Continuation?
    func events() -> AsyncStream<ConversationBackendEvent> {
        AsyncStream { continuation in lock.withLock { _continuation = continuation } }
    }
    /// Delivers `event` through the stream `events()` returned.
    func emit(_ event: ConversationBackendEvent) {
        _ = lock.withLock { _continuation }?.yield(event)
    }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        let (gate, historyMessages) = lock.withLock { () -> (PreparationGate?, [String: ConversationMessage]) in
            _historyCount += 1
            defer { _nextHistoryGate = nil }
            return (_nextHistoryGate, _historyMessages)
        }
        let shouldFail = lock.withLock { () -> Bool in
            guard _failNextHistory > 0 else { return false }
            _failNextHistory -= 1
            return true
        }
        if shouldFail { throw ConversationBackendError(code: -32001, message: "upstream timeout") }
        let upper = (beforeSeq ?? (total + 1)) - 1
        let lower = max(1, upper - limit + 1)
        guard upper >= 1 else { return ConversationHistoryPage(messages: [], hasMore: false) }
        let page = ConversationHistoryPage(
            messages: (lower...upper).map { historyMessages["m\($0)"] ?? makeMessage(seq: $0, sender: $0 % 3 == 0 ? "me" : "lc") },
            hasMore: lower > 1
        )
        if let gate { await gate.wait() }
        return page
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        let (hold, fail) = lock.withLock { () -> (Bool, Bool) in
            _sentClientIDs.append(draft.clientMessageID)
            _sentDrafts.append(draft)
            _sentEffects.append(draft.effect)
            let fail = _failNextSend
            _failNextSend = false
            return (_holdSend, fail)
        }
        if hold {
            await withCheckedContinuation { waiter in
                let resumeNow = lock.withLock { () -> Bool in
                    guard _holdSend else { return true }
                    _sendWaiters.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        defer { lock.withLock { _sendCount += 1 } }
        if fail { throw ConversationBackendError(code: -32002, message: "not delivered") }
        var message = makeMessage(seq: total + 1, sender: "me")
        message.clientMessageID = draft.clientMessageID
        message.text = draft.text
        message.mentions = draft.mentions
        message.textRuns = draft.textRuns
        message.effect = draft.effect
        message.delivery = .sent
        if stampAcksWithServerNow { message.sentAt = Date().addingTimeInterval(5) }
        return message
    }

    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        try await refuseHeldLocalAction()
        throw ConversationBackendError(code: -1, message: "unsupported")
    }

    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        try await refuseHeldLocalAction()
        var message = makeMessage(seq: Int(messageID.dropFirst()) ?? 0, sender: "me")
        message.text = text
        message.editedAt = Date()
        message.editCount = lock.withLock { _editCounts[messageID, default: 0] += 1; return _editCounts[messageID]! }
        return message
    }

    private var _editCounts: [String: Int] = [:]
    private var _failNextUnsend = false
    var failNextUnsend: Bool { get { lock.withLock { _failNextUnsend } } set { lock.withLock { _failNextUnsend = newValue } } }

    func unsend(messageID: String) async throws -> ConversationMessage {
        try await refuseHeldLocalAction()
        let fail = lock.withLock { () -> Bool in
            defer { _failNextUnsend = false }
            return _failNextUnsend
        }
        if fail { throw ConversationBackendError(code: -32003, message: "too late") }
        var message = makeMessage(seq: Int(messageID.dropFirst()) ?? 0, sender: "me")
        message.text = ""
        message.unsentAt = Date()
        return message
    }

    func setTyping(_ isTyping: Bool) async {}
    private var _markedRead: [Int] = []
    var markedRead: [Int] { lock.withLock { _markedRead } }
    func markRead(upToSeq: Int) async { lock.withLock { _markedRead.append(upToSeq) } }
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        ConversationAttachment(id: "up", kind: .image, width: 10, height: 10, url: nil)
    }
    func close() {}
    private var _linkPreviews: [URL: ConversationLinkPreview] = [:]
    var linkPreviews: [URL: ConversationLinkPreview] { get { lock.withLock { _linkPreviews } } set { lock.withLock { _linkPreviews = newValue } } }
    func linkPreview(for url: URL) async throws -> ConversationLinkPreview? { linkPreviews[url] }
}

@MainActor
@Suite struct ConversationStoreUpdateTests {
    @Test func editsAndTapbacksReplaceTheMessageInPlace() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var edited = backend.makeMessage(seq: 5, sender: "lc")
        edited.text = "edited"
        edited.editedAt = Date()
        edited.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        store.apply(.message(edited, eventSeq: 1))
        #expect(store.messages.count == 5)
        #expect(store.messages.last?.text == "edited")
        #expect(store.messages.last?.reactions.first?.reaction == .haha)
        var removed = edited
        removed.reactions = []
        store.apply(.message(removed, eventSeq: 2))
        #expect(store.messages.last?.reactions.isEmpty == true)
    }

    @Test func receiptsNeverRegress() {
        #expect(ConversationStore.maxDelivery(.read(nil), .delivered) == .read(nil))
        #expect(ConversationStore.maxDelivery(.delivered, .sent) == .delivered)
        #expect(ConversationStore.maxDelivery(.sending, .delivered) == .delivered)
        #expect(ConversationStore.maxDelivery(.failed("x"), .sent) == .sent)
    }

    @Test func olderPagesDoNotOverwriteNewerLiveState() async throws {
        let backend = ScriptedBackend(total: 60)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var live = backend.makeMessage(seq: 31, sender: "lc")
        live.text = "edited live"
        store.apply(.message(live, eventSeq: 1))
        store.loadOlder()
        try await waitUntil { store.messages.count == 60 }
        #expect(store.message(id: "m31")?.text == "edited live")
        #expect(store.messages.compactMap(\.seq) == Array(1...60))
    }

    @Test func singleOlderRequestInFlight() async throws {
        let backend = ScriptedBackend(total: 200)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.loadOlder()
        store.loadOlder()
        store.loadOlder()
        try await waitUntil { store.older == .idle }
        #expect(store.messages.count == 60)
    }
}

@MainActor
@Suite struct ConversationStoreWindowTests {
    @Test func updatesAboveTheLoadedWindowAreNotInserted() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var old = backend.makeMessage(seq: 12, sender: "lc")
        old.reactions = [ConversationReactionMark(participantID: "aw", reaction: .question)]
        store.apply(.message(old, eventSeq: 1))
        #expect(store.message(id: "m12") == nil)
        #expect(store.messages.compactMap(\.seq) == Array(71...100))
        store.loadOlder()
        try await waitUntil { store.messages.count == 60 }
        #expect(store.messages.compactMap(\.seq) == Array(41...100))
    }
}

@MainActor
@Suite struct ConversationStoreEditTests {
    @Test func editingMyRecentMessageAppliesAtOnceAndMarksEdited() async throws {
        let backend = ScriptedBackend(total: 6)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var mine = backend.makeMessage(seq: 7, sender: "me")
        mine.sentAt = Date()
        store.apply(.message(mine, eventSeq: 1))
        #expect(store.canEdit(mine))
        store.edit(messageID: "m7", text: "fixed typo")
        #expect(store.message(id: "m7")?.text == "fixed typo")
        #expect(store.message(id: "m7")?.editedAt != nil)
        let old = backend.makeMessage(seq: 3, sender: "me")
        #expect(!store.canEdit(old))
    }

    @Test func aMessageCanBeEditedFiveTimes() async throws {
        let backend = ScriptedBackend(total: 6)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var mine = backend.makeMessage(seq: 7, sender: "me")
        mine.sentAt = Date()
        store.apply(.message(mine, eventSeq: 1))
        for round in 1...5 {
            let current = try #require(store.message(id: "m7"))
            #expect(store.canEdit(current))
            store.edit(messageID: "m7", text: "version \(round)")
            try await waitUntil { store.message(id: "m7")?.editCount == round }
        }
        let done = try #require(store.message(id: "m7"))
        #expect(!store.canEdit(done))
        store.edit(messageID: "m7", text: "version 6")
        #expect(store.message(id: "m7")?.text == "version 5")
    }
}

extension ConversationStoreWindowTests {
    @Test func updatesDuringTheInitialLoadDoNotOpenAGap() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        // An old message's tapback and a brand-new message race the first page.
        var old = backend.makeMessage(seq: 12, sender: "lc")
        old.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        store.apply(.message(old, eventSeq: 1))
        store.apply(.message(backend.makeMessage(seq: 101, sender: "aw"), eventSeq: 2))
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.messages.compactMap(\.seq) == Array(71...101))
    }
}

extension ConversationStoreWindowTests {
    @Test func aFailedSendKeepsItsPlaceWhenLaterMessagesArrive() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-f" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "nope"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        var later = backend.makeMessage(seq: 4, sender: "lc")
        later.sentAt = Date().addingTimeInterval(5)
        store.apply(.message(later, eventSeq: 1))
        #expect(store.messages.last?.id == "m4")
        #expect(store.messages[store.messages.count - 2].rowID == rowID)
    }

    @Test func tryAgainMovesTheSendToTheBottomAtOnce() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-r" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "again"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        var later = backend.makeMessage(seq: 4, sender: "lc")
        later.sentAt = Date().addingTimeInterval(5)
        store.apply(.message(later, eventSeq: 1))
        #expect(store.messages.last?.id == "m4")
        // Try Again sends it now: it leaves its failed place for the bottom
        // while it is in flight, not only when the server acknowledges it.
        backend.holdSend = true
        store.retry(rowID: rowID)
        #expect(store.messages.last?.rowID == rowID)
        #expect(store.messages.last?.delivery == .sending)
        backend.releaseSend()
    }
}

@MainActor
@Suite struct ConversationStoreUnsendDeleteTests {
    private func loadedStore(_ backend: ScriptedBackend) async throws -> ConversationStore {
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        return store
    }

    @Test func undoSendTakesBackMyMessageAtOnceWithinTwoMinutes() async throws {
        let backend = ScriptedBackend(total: 6)
        let store = try await loadedStore(backend)
        var mine = backend.makeMessage(seq: 7, sender: "me")
        mine.sentAt = Date().addingTimeInterval(-30)
        store.apply(.message(mine, eventSeq: 1))
        #expect(store.canUnsend(mine))
        #expect(!store.canUnsend(mine, now: mine.sentAt.addingTimeInterval(ConversationStore.undoSendWindow + 1)))
        #expect(!store.canUnsend(backend.makeMessage(seq: 5, sender: "lc")))

        store.unsend(messageID: "m7")
        let unsent = try #require(store.message(id: "m7"))
        #expect(unsent.isUnsent)
        #expect(unsent.text.isEmpty)
        // The row stays (as a notice) and can't be edited or unsent again.
        #expect(store.messages.count == 7)
        #expect(!store.canEdit(unsent))
        #expect(!store.canUnsend(unsent))
        // A late echo of the original text must not resurrect it.
        var echo = mine
        echo.reactions = [ConversationReactionMark(participantID: "lc", reaction: .heart)]
        store.apply(.message(echo, eventSeq: 2))
        #expect(store.message(id: "m7")?.isUnsent == true)
        #expect(store.message(id: "m7")?.text.isEmpty == true)
    }

    @Test func refusedUndoSendKeepsTheNoticeMarkedNotUnsentAndCanBeRetried() async throws {
        let backend = ScriptedBackend(total: 6)
        let store = try await loadedStore(backend)
        var mine = backend.makeMessage(seq: 7, sender: "me")
        mine.sentAt = Date()
        store.apply(.message(mine, eventSeq: 1))
        #expect(store.lastSentByMe?.id == "m7")
        backend.failNextUnsend = true
        store.unsend(messageID: "m7")
        #expect(store.message(id: "m7")?.isUnsent == true)
        #expect(store.lastSentByMe?.id != "m7")
        // Messages keeps "You unsent a message" and appends "(!) Not Unsent".
        try await waitUntil { store.message(id: "m7")?.unsendFailed == true }
        let failed = try #require(store.message(id: "m7"))
        #expect(failed.isUnsent && failed.text.isEmpty)
        // The server's copy (still the original) must not bring the text back.
        store.apply(.message(mine, eventSeq: 2))
        #expect(store.message(id: "m7")?.unsendFailed == true)
        #expect(store.message(id: "m7")?.text.isEmpty == true)
        #expect(store.canRetryUnsend(failed))
        #expect(!store.canRetryUnsend(failed, now: mine.sentAt.addingTimeInterval(ConversationStore.undoSendWindow + 1)))

        store.retryUnsend(messageID: "m7")
        #expect(store.message(id: "m7")?.unsendFailed == false)
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.message(id: "m7")?.unsendFailed == false)
        #expect(store.message(id: "m7")?.isUnsent == true)
        #expect(!store.canRetryUnsend(try #require(store.message(id: "m7"))))
    }

    @Test func deletingSelectedMessagesRemovesThemForGood() async throws {
        let backend = ScriptedBackend(total: 10)
        let store = try await loadedStore(backend)
        let doomed = ["m4", "m5"].compactMap { store.message(id: $0)?.rowID }
        #expect(doomed.count == 2)
        store.deleteLocally(rowIDs: Set(doomed))
        #expect(store.messages.compactMap(\.seq) == [1, 2, 3, 6, 7, 8, 9, 10])
        // A later update (tapback) or a refetch must not bring it back.
        var update = backend.makeMessage(seq: 5, sender: "lc")
        update.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        store.apply(.message(update, eventSeq: 1))
        #expect(store.message(id: "m5") == nil)
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { store.messages.count == 8 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.message(id: "m4") == nil && store.message(id: "m5") == nil)
    }

    @Test func deletingAFailedSendDropsItAndItsRetryState() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-d" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "nope"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        store.deleteLocally(rowIDs: [rowID])
        #expect(store.message(rowID: rowID) == nil)
        #expect(store.messages.count == 3)
    }

    @Test func anUnsentMessageBreaksRunsAndCarriesNoStatus() {
        func message(_ seq: Int, unsent: Bool = false, delivery: ConversationDelivery? = .delivered) -> ConversationMessage {
            ConversationMessage(
                id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: "me",
                sentAt: Date(timeIntervalSince1970: TimeInterval(seq)), text: unsent ? "" : "t",
                unsentAt: unsent ? Date() : nil, delivery: delivery
            )
        }
        let plan = ConversationRunPlan(messages: [message(1), message(2, unsent: true), message(3)], meID: "me")
        // The bubble above the notice closes its run (tail); the one below starts a new run.
        #expect(plan.entries[0].isLastInRun)
        #expect(plan.entries[2].isFirstInRun)
        #expect(plan.entries[1].status == .none)
        let lastUnsent = ConversationRunPlan(messages: [message(1), message(2, unsent: true)], meID: "me")
        #expect(lastUnsent.entries[0].status == .delivered)
        #expect(lastUnsent.entries[1].status == .none)
    }
}

@Suite struct ConversationNoticeTests {
    @Test func messagesStatusTemplatesSplitAroundTheEmphasizedRun() {
        let mine = ConversationNotice(id: "n", messageID: "m", template: "#You# unsent a message")
        #expect(mine.leading.isEmpty && mine.emphasis == "You" && mine.trailing == " unsent a message")
        #expect(mine.text == "You unsent a message")

        let ja = ConversationNotice(id: "n", messageID: "m", template: "#%@#さんはメッセージの送信を取り消しました", argument: "Lawrence")
        #expect(ja.emphasis == "Lawrence" && ja.trailing == "さんはメッセージの送信を取り消しました")

        let failed = ConversationNotice(id: "n", messageID: "m", template: "#You# unsent a message. %@", failure: "(!) Not Unsent")
        #expect(failed.text == "You unsent a message. (!) Not Unsent")
        #expect(failed.trailingParts.before == " unsent a message. " && failed.trailingParts.after.isEmpty)

        let plain = ConversationNotice(id: "n", messageID: "m", template: "%@ unsent a message", argument: "Aziz")
        #expect(plain.emphasis.isEmpty && plain.text == "Aziz unsent a message")
    }
}

@MainActor
@Suite struct ConversationStoreTrimTests {
    private func loadedStore(total: Int, pages: Int) async throws -> (ScriptedBackend, ConversationStore) {
        let backend = ScriptedBackend(total: total)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        for page in 1..<pages {
            store.loadOlder()
            try await waitUntil { store.messages.count == 30 * (page + 1) }
        }
        return (backend, store)
    }

    @Test func trimKeepsTheNewestMessagesAndPagesBackIn() async throws {
        let (_, store) = try await loadedStore(total: 200, pages: 4)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        #expect(store.messages.compactMap(\.seq) == Array(81...200))
        #expect(store.trimOlder(keepingNewest: 50))
        #expect(store.messages.compactMap(\.seq) == Array(151...200))
        #expect(store.message(id: "m100") == nil)
        #expect(store.message(id: "m151")?.seq == 151)
        #expect(store.older == .idle)
        #expect(changes == [.reset])
        store.loadOlder()
        try await waitUntil { store.messages.count == 80 }
        #expect(store.messages.compactMap(\.seq) == Array(121...200))
    }

    @Test func trimKeepsMessagesThatKeptRepliesQuote() async throws {
        let (backend, store) = try await loadedStore(total: 120, pages: 4)
        var reply = backend.makeMessage(seq: 121, sender: "lc")
        reply.replyToID = "m20"
        store.apply(.message(reply, eventSeq: 1))
        #expect(store.trimOlder(keepingNewest: 10))
        #expect(store.messages.first?.seq == 20)
        #expect(store.message(id: "m20") != nil)
    }

    @Test func trimNeverDropsAFailedSendOrRunsWhilePaging() async throws {
        let (backend, store) = try await loadedStore(total: 100, pages: 2)
        backend.failNextSend = true
        store.send(text: "unsent")
        try await waitUntil { store.messages.contains { $0.delivery?.isFailed == true } }
        for seq in 101...140 { store.apply(.message(backend.makeMessage(seq: seq, sender: "lc"), eventSeq: seq)) }
        #expect(store.trimOlder(keepingNewest: 10))
        #expect(store.messages.contains { $0.text == "unsent" })
        store.loadOlder()
        #expect(store.older == .loading)
        #expect(!store.trimOlder(keepingNewest: 5))
    }

    @Test func trimKeepsRowsTheInterfaceHoldsOpen() async throws {
        let (_, store) = try await loadedStore(total: 120, pages: 4)
        #expect(store.trimOlder(keepingNewest: 10, preserving: ["s:m40"]))
        #expect(store.messages.first?.seq == 40)
        #expect(store.trimOlder(keepingNewest: 10, preserving: ["m90"]))
        #expect(store.messages.first?.seq == 90)
    }

    @Test func trimKeepsThePendingCatchUpTargetAndExactUnreadCount() async throws {
        let (backend, store) = try await loadedStore(total: 120, pages: 4)
        store.apply(.readState(ConversationReadState(lastReadSeq: 50, unreadCount: 46, headSeq: 120)))
        store.setViewing(true)
        #expect(store.catchUpTarget?.seq == 52)
        #expect(store.trimOlder(keepingNewest: 10))
        // The marker message stays so the target is still known to be first.
        #expect(store.messages.first?.seq == 50)
        #expect(store.catchUpTarget?.seq == 52)
        store.dismissCatchUp()
        #expect(store.trimOlder(keepingNewest: 10))
        #expect(store.messages.first?.seq == 111)
        #expect(store.unreadCount == 0)
        store.setViewing(false)
        store.apply(.message(backend.makeMessage(seq: 121, sender: "lc"), eventSeq: 1))
        #expect(store.unreadCount == 1)
    }

    @Test func trimIfLargeOnlyAboveThreshold() async throws {
        let (_, store) = try await loadedStore(total: 100, pages: 2)
        #expect(!store.trimOlderIfLarge())
        #expect(store.messages.count == 60)
    }
}

@MainActor
@Suite struct ConversationStoreOrderTests {
    /// Acknowledged messages ascend by seq; sends in flight follow, oldest first.
    private func expectOrdered(_ store: ConversationStore, sourceLocation: SourceLocation = #_sourceLocation) {
        let acked = store.messages.prefix { $0.seq != nil }
        #expect(acked.compactMap(\.seq) == acked.compactMap(\.seq).sorted(), sourceLocation: sourceLocation)
        let pending = store.messages.dropFirst(acked.count)
        #expect(pending.allSatisfy { $0.seq == nil }, sourceLocation: sourceLocation)
        #expect(pending.map(\.sentAt) == pending.map(\.sentAt).sorted(), sourceLocation: sourceLocation)
        for (index, message) in store.messages.enumerated() {
            #expect(store.message(id: message.id) == message, sourceLocation: sourceLocation)
            _ = index
        }
    }

    @Test func sendsAcksAndArrivalsStayOrderedAndIndexed() async throws {
        let backend = ScriptedBackend(total: 50)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var eventSeq = 0
        for round in 0..<4 {
            backend.holdSend = true
            store.send(text: "send \(round)")
            expectOrdered(store)
            // Someone else's message lands while mine is in flight: it sorts above it.
            eventSeq += 1
            backend.total += 1
            store.apply(.message(backend.makeMessage(seq: backend.total, sender: "lc"), eventSeq: eventSeq))
            expectOrdered(store)
            #expect(store.messages.last?.text == "send \(round)")
            backend.releaseSend()
            try await waitUntil { store.messages.allSatisfy { $0.seq != nil } }
            backend.total += 1
            expectOrdered(store)
        }
        #expect(store.messages.filter { $0.text.hasPrefix("send") }.count == 4)
    }
}
