import CmuxAgentReplica
import CmuxAgentSync
import CmuxAgentWire
import Foundation
import Testing

@MainActor
extension AgentSyncEngineTests {
    @Test
    func needsTailPullDebounceCoalescesGapFrames() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [AgentSyncTestSupport.entry(1)])
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(transport: transport, syncClock: clock)
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })
        await server.setEntriesResult(AgentSyncTestSupport.page(entries: [
            AgentSyncTestSupport.entry(1),
            AgentSyncTestSupport.entry(2),
            AgentSyncTestSupport.entry(3),
            AgentSyncTestSupport.entry(4),
        ]))

        for sequence in [3, 4] {
            let frame = try AgentSyncTestSupport.eventData(.entriesAppended(
                GuiEntriesAppendedEvent(
                    journalID: AgentSyncTestSupport.journalOne,
                    entries: [AgentSyncTestSupport.entry(sequence)]
                )
            ))
            await transport.injectFrame(
                topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
                payload: frame
            )
            #expect(await AgentSyncTestSupport.waitUntil { await clock.pendingSleepCount() == 1 })
        }
        #expect(conversation.needsTailPull)
        #expect(await server.requestCount(method: GuiWireMethod.entries) == 1)

        await clock.advance(milliseconds: 250)
        #expect(await AgentSyncTestSupport.waitUntil {
            await server.requestCount(method: GuiWireMethod.entries) == 2
        })
        #expect(await AgentSyncTestSupport.waitUntil { conversation.entries.count == 4 })
        #expect(conversation.entries.map(\.seq.rawValue) == [1, 2, 3, 4])
    }

    @Test
    func streamTickRequiresContiguousTextAndClearsOnMismatchedEmptyTickOrAppend() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [
            AgentSyncTestSupport.entry(1),
            AgentSyncTestSupport.entry(2),
        ])
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport)
        _ = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        let contiguous = try AgentSyncTestSupport.eventData(.streamTick(
            GuiStreamTickEvent(
                journalID: AgentSyncTestSupport.journalOne,
                afterSeq: EntrySeq(rawValue: 2),
                textTail: "working",
                revision: 1
            )
        ))
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: contiguous
        )
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.streamingTails[AgentSyncTestSupport.session]?.revision == 1
        })

        let noncontiguous = try AgentSyncTestSupport.eventData(.streamTick(
            GuiStreamTickEvent(
                journalID: AgentSyncTestSupport.journalOne,
                afterSeq: EntrySeq(rawValue: 3),
                textTail: "wrong tail",
                revision: 2
            )
        ))
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: noncontiguous
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.streamingTails[AgentSyncTestSupport.session]?.revision == 1)

        let mismatchedClear = try AgentSyncTestSupport.eventData(.streamTick(
            GuiStreamTickEvent(
                journalID: AgentSyncTestSupport.journalOne,
                afterSeq: EntrySeq(rawValue: 3),
                textTail: "",
                revision: 2
            )
        ))
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: mismatchedClear
        )
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.streamingTails[AgentSyncTestSupport.session] == nil
        })

        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: contiguous
        )
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.streamingTails[AgentSyncTestSupport.session]?.revision == 1
        })

        let append = try AgentSyncTestSupport.eventData(.entriesAppended(
            GuiEntriesAppendedEvent(
                journalID: AgentSyncTestSupport.journalOne,
                entries: [AgentSyncTestSupport.entry(3)]
            )
        ))
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: append
        )
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.streamingTails[AgentSyncTestSupport.session] == nil
        })
    }

    @Test
    func unknownFrameIsIgnored() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [AgentSyncTestSupport.entry(1)])
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport)
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })
        let state = conversation.state
        let helloCount = await server.requestCount(method: GuiWireMethod.hello)

        let unknown = try AgentSyncTestSupport.eventData(.unknown("future_event"))
        await transport.injectFrame(topic: GuiWireTopic.sessions, payload: unknown)
        for _ in 0..<50 { await Task.yield() }

        #expect(conversation.state == state)
        #expect(await server.requestCount(method: GuiWireMethod.hello) == helloCount)
        #expect(engine.malformedFrameCount == 0)
    }

    @Test
    func threeMalformedFramesWithinTenSecondsForceResync() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.install(on: transport)
        let clock = TestSyncClock(currentMilliseconds: 9_000)
        let engine = AgentSyncEngine(transport: transport, syncClock: clock)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        for _ in 0..<3 {
            await transport.injectFrame(
                topic: GuiWireTopic.sessions,
                payload: Data("{".utf8)
            )
        }
        #expect(await AgentSyncTestSupport.waitUntil {
            await server.requestCount(method: GuiWireMethod.hello) == 2
                && engine.connectivity.phase == .connected
        })
        #expect(engine.malformedFrameCount == 3)
        #expect(engine.connectivity.phase == .connected)
    }

    @Test
    func malformedFrameWindowExpiresBeforeThreshold() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(transport: transport, syncClock: clock)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        for _ in 0..<2 {
            await transport.injectFrame(topic: GuiWireTopic.sessions, payload: Data("{".utf8))
        }
        #expect(await AgentSyncTestSupport.waitUntil { engine.malformedFrameCount == 2 })
        await clock.advance(milliseconds: 10_001)
        await transport.injectFrame(topic: GuiWireTopic.sessions, payload: Data("{".utf8))
        #expect(await AgentSyncTestSupport.waitUntil { engine.malformedFrameCount == 3 })
        for _ in 0..<20 { await Task.yield() }
        #expect(await server.requestCount(method: GuiWireMethod.hello) == 1)

        for _ in 0..<2 {
            await transport.injectFrame(topic: GuiWireTopic.sessions, payload: Data("{".utf8))
        }
        #expect(await AgentSyncTestSupport.waitUntil {
            await server.requestCount(method: GuiWireMethod.hello) == 2
                && engine.connectivity.phase == .connected
        })
    }

    @Test
    func capabilitiesResultIsCachedPerSession() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        let report = GuiCapabilitiesResult(
            tier: .hooked,
            reasons: [GuiCapabilityReason(code: "limited", detail: "fixture")],
            cliVersion: "2.3.4",
            steerable: true,
            answerable: false
        )
        await server.setCapabilitiesResult(report)
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        let returned = try await engine.capabilities(sessionID: AgentSyncTestSupport.session)

        #expect(returned == report)
        #expect(engine.cachedCapabilities[AgentSyncTestSupport.session] == report)
        #expect(await server.requestCount(method: GuiWireMethod.capabilities) == 1)
    }

    @Test
    func interruptAndAnswerRejectOfflineWithoutRequests() async {
        let transport = FixtureSyncTransport()
        let engine = AgentSyncEngine(transport: transport)
        defer { engine.stop() }

        await #expect(throws: AgentSyncError.offline) {
            try await engine.interrupt(sessionID: AgentSyncTestSupport.session, hard: true)
        }
        await #expect(throws: AgentSyncError.offline) {
            try await engine.answer(sessionID: AgentSyncTestSupport.session, askID: "ask-1", choice: 0)
        }
        #expect(await transport.calls().isEmpty)
    }

    @Test
    func loadOlderUsesWindowMinimumAndExposesHasMoreBefore() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(3), AgentSyncTestSupport.entry(4)],
            windowStart: 3,
            windowEnd: 4,
            tail: 4,
            hasMoreBefore: true
        ))
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(transport: transport, syncClock: clock)
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })
        #expect(engine.hasMoreBeforeBySession[AgentSyncTestSupport.session] == true)

        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(1), AgentSyncTestSupport.entry(2)],
            windowStart: 1,
            windowEnd: 2,
            tail: 4,
            hasMoreBefore: false
        ))
        try await engine.loadOlder(sessionID: AgentSyncTestSupport.session)

        let params = await server.entriesParams()
        #expect(params.last?.beforeSeq == EntrySeq(rawValue: 3))
        #expect(conversation.entries.map(\.seq.rawValue) == [1, 2, 3, 4])
        #expect(engine.hasMoreBeforeBySession[AgentSyncTestSupport.session] == false)
    }

    @Test
    func cursorLoadOlderCoalescesConcurrentRequestsAndMergesSparseOffsets() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(10_000), AgentSyncTestSupport.entry(20_000)],
            tail: 20_000,
            hasMoreBefore: true,
            startCursor: "start-10000",
            endCursor: "tail-20000",
            tailCursor: "tail-20000"
        ))
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport, syncClock: TestSyncClock())
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(1_000), AgentSyncTestSupport.entry(5_000)],
            tail: 20_000,
            hasMoreBefore: false,
            hasMoreAfter: true,
            startCursor: "head-1000",
            endCursor: "start-10000",
            tailCursor: "tail-20000"
        ))
        await server.gateNextEntriesRequest()
        async let first: Void = engine.loadOlder(sessionID: AgentSyncTestSupport.session)
        async let second: Void = engine.loadOlder(sessionID: AgentSyncTestSupport.session)
        #expect(await AgentSyncTestSupport.waitUntil {
            await server.requestCount(method: GuiWireMethod.entries) == 2
        })
        await server.resumeEntriesRequest()
        try await first
        try await second

        let params = await server.entriesParams()
        #expect(params.last?.anchor == .before)
        #expect(params.last?.cursor == JournalCursor(rawValue: "start-10000"))
        #expect(await server.requestCount(method: GuiWireMethod.entries) == 2)
        #expect(conversation.entries.map(\.seq.rawValue) == [1_000, 5_000, 10_000, 20_000])
        #expect(conversation.holes.isEmpty)
        #expect(conversation.unreadCount == 4)
        #expect(!conversation.needsTailPull)
    }

    @Test
    func cursorLoadNewerAdvancesOnePageWithoutSchedulingTailJump() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(151), AgentSyncTestSupport.entry(200)],
            tail: 200,
            hasMoreBefore: true,
            startCursor: "c150",
            endCursor: "c200",
            tailCursor: "c200"
        ))
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(transport: transport, syncClock: clock)
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(1), AgentSyncTestSupport.entry(50)],
            tail: 200,
            hasMoreAfter: true,
            startCursor: "c0",
            endCursor: "c50",
            tailCursor: "c200"
        ))
        try await engine.jumpToHead(sessionID: AgentSyncTestSupport.session)

        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(51), AgentSyncTestSupport.entry(100)],
            tail: 200,
            hasMoreBefore: true,
            hasMoreAfter: true,
            startCursor: "c50",
            endCursor: "c100",
            tailCursor: "c200"
        ))
        try await engine.loadNewer(sessionID: AgentSyncTestSupport.session)

        #expect(conversation.entries.map(\.seq.rawValue) == [1, 50, 51, 100])
        #expect(conversation.endCursor == JournalCursor(rawValue: "c100"))
        #expect(conversation.hasMoreAfter)
        #expect(!conversation.needsTailPull)
        #expect(await clock.pendingSleepCount() == 0)
        #expect(await server.requestCount(method: GuiWireMethod.entries) == 3)

        await clock.advance(milliseconds: 250)
        for _ in 0..<50 { await Task.yield() }
        #expect(await server.requestCount(method: GuiWireMethod.entries) == 3)
    }

    @Test
    func jumpToHeadRetriesOnceAfterJournalRotationRestart() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setEntriesResult(AgentSyncTestSupport.page(
            entries: [AgentSyncTestSupport.entry(90), AgentSyncTestSupport.entry(100)],
            tail: 100,
            hasMoreBefore: true,
            startCursor: "old-90",
            endCursor: "old-100",
            tailCursor: "old-100"
        ))
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport, syncClock: TestSyncClock())
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        await server.enqueueEntriesResult(AgentSyncTestSupport.page(
            journalID: AgentSyncTestSupport.journalTwo,
            entries: [
                AgentSyncTestSupport.entry(900, journalID: AgentSyncTestSupport.journalTwo),
                AgentSyncTestSupport.entry(1_000, journalID: AgentSyncTestSupport.journalTwo),
            ],
            tail: 1_000,
            hasMoreBefore: true,
            startCursor: "new-900",
            endCursor: "new-1000",
            tailCursor: "new-1000",
            requiresPagingRestart: true
        ))
        await server.enqueueEntriesResult(AgentSyncTestSupport.page(
            journalID: AgentSyncTestSupport.journalTwo,
            entries: [
                AgentSyncTestSupport.entry(10, journalID: AgentSyncTestSupport.journalTwo),
                AgentSyncTestSupport.entry(20, journalID: AgentSyncTestSupport.journalTwo),
            ],
            tail: 1_000,
            hasMoreAfter: true,
            startCursor: "new-0",
            endCursor: "new-20",
            tailCursor: "new-1000"
        ))

        try await engine.jumpToHead(sessionID: AgentSyncTestSupport.session)

        #expect(conversation.journalID == AgentSyncTestSupport.journalTwo)
        #expect(conversation.entries.map(\.seq.rawValue) == [10, 20])
        #expect(conversation.startCursor == JournalCursor(rawValue: "new-0"))
        #expect(conversation.endCursor == JournalCursor(rawValue: "new-20"))
        let params = await server.entriesParams()
        #expect(params.suffix(2).map(\.anchor) == [.head, .head])
        #expect(params.suffix(2).map(\.journalID) == [
            AgentSyncTestSupport.journalOne,
            AgentSyncTestSupport.journalTwo,
        ])
        #expect(await server.requestCount(method: GuiWireMethod.entries) == 3)
    }
}
