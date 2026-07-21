import CmuxAgentReplica
import CmuxAgentSync
import CmuxAgentWire
import Foundation
import Testing

@MainActor
@Suite
struct AgentSyncEngineTests {
    @Test
    func subscribeHappensBeforeAuthoritativePulls() async throws {
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

        let calls = await transport.calls()
        let helloIndex = try #require(calls.firstIndex { $0.method == GuiWireMethod.hello })
        let subscribeIndex = try #require(calls.firstIndex { $0.kind == .subscribe })
        let sessionsIndex = try #require(calls.firstIndex { $0.method == GuiWireMethod.sessions })
        let entriesIndex = try #require(calls.firstIndex { $0.method == GuiWireMethod.entries })
        #expect(helloIndex < subscribeIndex)
        #expect(subscribeIndex < sessionsIndex)
        #expect(subscribeIndex < entriesIndex)
        #expect(calls[subscribeIndex].topics == [
            GuiWireTopic.sessions,
            GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
        ])
    }

    @Test
    func closingOneConversationKeepsOtherConversationLive() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [AgentSyncTestSupport.entry(1)])
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport)
        _ = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        let remainingConversation = engine.openConversation(sessionID: AgentSyncTestSupport.otherSession)
        defer { engine.stop() }

        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil {
            let entriesCount = await server.requestCount(method: GuiWireMethod.entries)
            return engine.connectivity.phase == .connected && entriesCount == 2
        })

        engine.closeConversation(sessionID: AgentSyncTestSupport.session)
        #expect(await AgentSyncTestSupport.waitUntil {
            let entriesCount = await server.requestCount(method: GuiWireMethod.entries)
            return engine.connectivity.phase == .connected && entriesCount == 3
        })

        let append = try AgentSyncTestSupport.eventData(
            .entriesAppended(GuiEntriesAppendedEvent(
                journalID: AgentSyncTestSupport.journalOne,
                entries: [AgentSyncTestSupport.entry(2)]
            )),
            sessionID: AgentSyncTestSupport.otherSession
        )
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.otherSession),
            payload: append
        )
        #expect(await AgentSyncTestSupport.waitUntil { remainingConversation.entries.count == 2 })

        let latestSubscription = await transport.calls().last { $0.kind == .subscribe }
        #expect(latestSubscription?.topics == [
            GuiWireTopic.sessions,
            GuiWireTopic.journal(sessionID: AgentSyncTestSupport.otherSession),
        ])
        #expect(remainingConversation.entries.map(\.seq.rawValue) == [1, 2])
    }

    @Test
    func offlineSendQueueFlushesFIFOWithPerItemAcknowledgements() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setSendOutcomes([.accepted, .failure(.inputQueueFull), .rejected])
        await server.install(on: transport)
        let engine = AgentSyncEngine(
            transport: transport,
            replicaClock: AgentSyncReplicaClock(initialValue: 10),
            ticketIDGenerator: SequentialTicketIDGenerator()
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }

        _ = engine.send(sessionID: AgentSyncTestSupport.session, text: "one")
        _ = engine.send(sessionID: AgentSyncTestSupport.session, text: "two")
        _ = engine.send(sessionID: AgentSyncTestSupport.session, text: "three")
        #expect(conversation.sendTickets.map(\.state) == [.queuedLocal, .queuedLocal, .queuedLocal])

        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        let sends = await server.sendParams()
        #expect(sends.compactMap(\.text) == ["one", "two", "three"])
        #expect(conversation.sendTickets.map(\.state) == [
            .acceptedByMac,
            .failed(code: "input_queue_full"),
            .failed(code: "send_rejected"),
        ])
    }

    @Test
    func failedSendRetriesWithTheSameIdempotencyKey() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setSendOutcomes([.rejected, .accepted])
        await server.install(on: transport)
        let engine = AgentSyncEngine(
            transport: transport,
            ticketIDGenerator: SequentialTicketIDGenerator()
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        let ticketID = engine.send(sessionID: AgentSyncTestSupport.session, text: "retry me")
        #expect(await AgentSyncTestSupport.waitUntil {
            conversation.sendTickets.first(where: { $0.id == ticketID })?.state == .failed(code: "send_rejected")
        })
        #expect(engine.retrySend(sessionID: AgentSyncTestSupport.session, ticketID: ticketID))
        #expect(await AgentSyncTestSupport.waitUntil {
            conversation.sendTickets.first(where: { $0.id == ticketID })?.state == .acceptedByMac
        })

        let sends = await server.sendParams()
        #expect(sends.map(\.ticketID) == [ticketID.uuidString, ticketID.uuidString])
        #expect(conversation.sendTickets.count == 1)
    }

    @Test
    func transportFailureMidFlushLeavesRemainingTicketsQueuedForRetry() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.setSendOutcomes([.accepted, .transportFailure, .accepted])
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            replicaClock: AgentSyncReplicaClock(initialValue: 20),
            ticketIDGenerator: SequentialTicketIDGenerator()
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        _ = engine.send(sessionID: AgentSyncTestSupport.session, text: "one")
        _ = engine.send(sessionID: AgentSyncTestSupport.session, text: "two")
        _ = engine.send(sessionID: AgentSyncTestSupport.session, text: "three")

        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil {
            let sendCount = await server.requestCount(method: GuiWireMethod.send)
            let sleepCount = await clock.sleepRequests().count
            return sendCount == 2 && sleepCount == 1
        })

        #expect(engine.connectivity.phase != .connected)
        #expect(await server.sendParams().compactMap(\.text) == ["one", "two"])
        #expect(conversation.sendTickets.map(\.state) == [
            .acceptedByMac,
            .queuedLocal,
            .queuedLocal,
        ])
    }

    @Test
    func reconnectWithGapPullsTailAndFlushesQueuedTicket() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [
            AgentSyncTestSupport.entry(1),
            AgentSyncTestSupport.entry(2),
        ])
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            ticketIDGenerator: SequentialTicketIDGenerator()
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        await transport.injectConnectionEvent(.down(reason: "link lost"))
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.connectivity.phase == .offline(reason: "link lost")
        })
        let ticketID = engine.send(sessionID: AgentSyncTestSupport.session, text: "queued offline")
        await server.setEntriesResult(AgentSyncTestSupport.page(entries: [
            AgentSyncTestSupport.entry(1),
            AgentSyncTestSupport.entry(2),
            AgentSyncTestSupport.entry(3),
            AgentSyncTestSupport.entry(4),
        ]))
        let gapFrame = try AgentSyncTestSupport.eventData(.entriesAppended(
            GuiEntriesAppendedEvent(
                journalID: AgentSyncTestSupport.journalOne,
                entries: [AgentSyncTestSupport.entry(4)]
            )
        ))
        await server.setSessionsRequestAction {
            await transport.injectFrame(
                topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
                payload: gapFrame
            )
            #expect(await AgentSyncTestSupport.waitUntil { conversation.needsTailPull })
        }

        await transport.injectConnectionEvent(.up)
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.connectivity.phase == .connected && conversation.entries.count == 4
        })

        #expect(conversation.entries.map(\.seq.rawValue) == [1, 2, 3, 4])
        #expect(conversation.holes.isEmpty)
        #expect(!conversation.needsTailPull)
        #expect(conversation.sendTickets.first(where: { $0.id == ticketID })?.state == .acceptedByMac)
        #expect(await server.requestCount(method: GuiWireMethod.entries) >= 2)
    }

    @Test
    func journalRotationMidStreamSwapsWindowAndKeepsTickets() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [
            AgentSyncTestSupport.entry(1),
            AgentSyncTestSupport.entry(2),
        ])
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            ticketIDGenerator: SequentialTicketIDGenerator()
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })
        let ticketID = engine.send(sessionID: AgentSyncTestSupport.session, text: "keep me")
        #expect(await AgentSyncTestSupport.waitUntil {
            conversation.sendTickets.first(where: { $0.id == ticketID })?.state == .acceptedByMac
        })
        #expect(conversation.lastAppliedOrigin == .live)

        await server.setEntriesResult(AgentSyncTestSupport.page(
            journalID: AgentSyncTestSupport.journalTwo,
            entries: [
                AgentSyncTestSupport.entry(1, journalID: AgentSyncTestSupport.journalTwo, hash: 201),
                AgentSyncTestSupport.entry(2, journalID: AgentSyncTestSupport.journalTwo, hash: 202),
                AgentSyncTestSupport.entry(3, journalID: AgentSyncTestSupport.journalTwo, hash: 203),
            ]
        ))
        let reset = try AgentSyncTestSupport.eventData(.journalReset(
            GuiJournalResetEvent(
                sessionID: AgentSyncTestSupport.session,
                newJournalID: AgentSyncTestSupport.journalTwo,
                tailSeq: EntrySeq(rawValue: 3)
            )
        ))
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: reset
        )
        #expect(await AgentSyncTestSupport.waitUntil { await clock.pendingSleepCount() == 1 })
        await clock.advance(milliseconds: 250)
        #expect(await AgentSyncTestSupport.waitUntil {
            conversation.journalID == AgentSyncTestSupport.journalTwo && conversation.entries.count == 3
        })

        #expect(conversation.entries.map(\.content.contentHash) == [201, 202, 203])
        #expect(conversation.resetMarkerCount == 1)
        #expect(conversation.sendTickets.map(\.id).contains(ticketID))
    }

    @Test
    func macRelaunchDropsReplicatedStateButKeepsTicketsAndReadPointer() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [
            AgentSyncTestSupport.entry(1, hash: 101),
            AgentSyncTestSupport.entry(2, hash: 102),
        ])
        await server.install(on: transport)
        let engine = AgentSyncEngine(
            transport: transport,
            ticketIDGenerator: SequentialTicketIDGenerator()
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })
        conversation.markReadThrough(EntrySeq(rawValue: 2))
        let ticketID = engine.send(sessionID: AgentSyncTestSupport.session, text: "survive relaunch")
        #expect(await AgentSyncTestSupport.waitUntil {
            conversation.sendTickets.first(where: { $0.id == ticketID })?.state == .acceptedByMac
        })

        await server.setEpoch(AgentSyncTestSupport.epochTwo)
        await server.setSessions([
            AgentSyncTestSupport.sessionSnapshot(title: "Relaunched", version: 2),
        ], epoch: AgentSyncTestSupport.epochTwo)
        await server.setEntriesResult(AgentSyncTestSupport.page(
            journalID: AgentSyncTestSupport.journalTwo,
            entries: [
                AgentSyncTestSupport.entry(1, journalID: AgentSyncTestSupport.journalTwo, hash: 301),
                AgentSyncTestSupport.entry(2, journalID: AgentSyncTestSupport.journalTwo, hash: 302),
                AgentSyncTestSupport.entry(3, journalID: AgentSyncTestSupport.journalTwo, hash: 303),
            ]
        ))

        await transport.injectConnectionEvent(.reset)
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.connectivity.phase == .connected
                && engine.directory.epoch == AgentSyncTestSupport.epochTwo
                && conversation.journalID == AgentSyncTestSupport.journalTwo
        })

        #expect(engine.directory.sessions.map(\.title) == ["Relaunched"])
        #expect(conversation.entries.map(\.content.contentHash) == [301, 302, 303])
        #expect(conversation.readPointer == EntrySeq(rawValue: 2))
        #expect(conversation.sendTickets.map(\.id).contains(ticketID))
    }

    @Test
    func sessionsEpochChangeDropsOpenConversationBeforeMergingNewVersions() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [
            AgentSyncTestSupport.entry(1, version: 10, hash: 100),
        ])
        await server.install(on: transport)
        let engine = AgentSyncEngine(transport: transport)
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        let tick = try AgentSyncTestSupport.eventData(.streamTick(GuiStreamTickEvent(
            journalID: AgentSyncTestSupport.journalOne,
            afterSeq: EntrySeq(rawValue: 1),
            textTail: "old epoch",
            revision: 1
        )))
        await transport.injectFrame(
            topic: GuiWireTopic.journal(sessionID: AgentSyncTestSupport.session),
            payload: tick
        )
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.streamingTails[AgentSyncTestSupport.session] != nil
        })

        await server.setHelloEpoch(AgentSyncTestSupport.epochOne)
        await server.setSessions(
            [AgentSyncTestSupport.sessionSnapshot(title: "New epoch")],
            epoch: AgentSyncTestSupport.epochTwo
        )
        await server.setEntriesResult(AgentSyncTestSupport.page(entries: [
            AgentSyncTestSupport.entry(1, version: 1, hash: 200),
        ]))
        engine.noteAppForegrounded()

        #expect(await AgentSyncTestSupport.waitUntil {
            engine.connectivity.phase == .connected
                && engine.directory.epoch == AgentSyncTestSupport.epochTwo
                && conversation.entries.first?.content.contentHash == 200
        })
        #expect(engine.streamingTails[AgentSyncTestSupport.session] == nil)
        #expect(conversation.entries.map(\.version.rawValue) == [1])
    }

    @Test
    func duplicateAndReorderedFramesDuringPullConvergeToCleanState() async throws {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer(entries: [AgentSyncTestSupport.entry(1)])
        await server.install(on: transport)
        let clock = TestSyncClock()
        let replicaClock = ManualReplicaClock(currentTick: 10)
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            replicaClock: replicaClock
        )
        let conversation = engine.openConversation(sessionID: AgentSyncTestSupport.session)
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { engine.connectivity.phase == .connected })

        let cleanEntries = [
            AgentSyncTestSupport.entry(1),
            AgentSyncTestSupport.entry(2),
            AgentSyncTestSupport.entry(3),
        ]
        await server.setEntriesResult(AgentSyncTestSupport.page(entries: cleanEntries))
        await server.gateNextEntriesRequest()
        engine.noteNetworkPathChanged()
        #expect(await AgentSyncTestSupport.waitUntil {
            await server.requestCount(method: GuiWireMethod.entries) == 2
        })

        for sequence in [3, 2, 3] {
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
        }
        #expect(await AgentSyncTestSupport.waitUntil { conversation.needsTailPull })
        await server.resumeEntriesRequest()
        #expect(await AgentSyncTestSupport.waitUntil {
            engine.connectivity.phase == .connected && conversation.entries.count == 3
        })

        let clean = ConversationReplica(
            sessionID: AgentSyncTestSupport.session,
            clock: ManualReplicaClock(currentTick: 10)
        )
        clean.mergePage(
            journal: AgentSyncTestSupport.journalOne,
            entries: cleanEntries,
            windowStart: EntrySeq(rawValue: 1),
            windowEnd: EntrySeq(rawValue: 3),
            tailSeq: EntrySeq(rawValue: 3),
            hasMoreBefore: false
        )
        #expect(conversation.state == clean.state)
    }

    @Test
    func exponentialBackoffUsesClockAndCapsBeforeJitter() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.failNextHelloRequests(20)
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            jitter: FixedAgentSyncJitter(fraction: 0.2)
        )
        defer { engine.stop() }
        engine.start()

        let expected = [600, 1_200, 2_400, 4_800, 9_600, 19_200, 19_200]
        for (index, delay) in expected.enumerated() {
            #expect(await AgentSyncTestSupport.waitUntil {
                await clock.sleepRequests().count == index + 1
            })
            #expect(await clock.sleepRequests()[index] == delay)
            await clock.advance(milliseconds: delay)
        }
    }

    @Test
    func foregroundEventSkipsPendingBackoff() async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.failNextHelloRequests(1)
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            jitter: FixedAgentSyncJitter(fraction: 0)
        )
        defer { engine.stop() }
        engine.start()
        #expect(await AgentSyncTestSupport.waitUntil { await clock.sleepRequests() == [500] })

        engine.noteAppForegrounded()
        #expect(await AgentSyncTestSupport.waitUntil {
            let helloCount = await server.requestCount(method: GuiWireMethod.hello)
            return engine.connectivity.phase == .connected && helloCount == 2
        })
        #expect(await clock.nowMilliseconds() == 0)
    }

    @Test(arguments: [
        (-1.0, 400),
        (-0.2, 400),
        (0.0, 500),
        (0.2, 600),
        (1.0, 600),
    ])
    func retryJitterIsClampedToTwentyPercent(fraction: Double, expectedDelay: Int) async {
        let transport = FixtureSyncTransport()
        let server = AgentSyncTestServer()
        await server.failNextHelloRequests(1)
        await server.install(on: transport)
        let clock = TestSyncClock()
        let engine = AgentSyncEngine(
            transport: transport,
            syncClock: clock,
            jitter: FixedAgentSyncJitter(fraction: fraction)
        )
        defer { engine.stop() }
        engine.start()

        #expect(await AgentSyncTestSupport.waitUntil { await clock.sleepRequests().count == 1 })
        #expect(await clock.sleepRequests() == [expectedDelay])
    }

}
