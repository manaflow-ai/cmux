import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A clock whose time moves only when the test sets it; nothing sleeps on it.
private final class StillClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let offset = Mutex(Duration.zero)
    var now: Instant { Instant(offset: offset.withLock { $0 }) }
    var minimumResolution: Duration { .zero }

    func advance(by duration: Duration) { offset.withLock { $0 += duration } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws { throw CancellationError() }
}

/// The cause of a daemon event (plans/cmux-next/chrome-parity/p06-scheduler.md, "Person cause, app
/// side"): the echo of a mutation this app sent applies in the cause of the scope that sent it,
/// anything else in the envelope's cause, and an old daemon's events as `program`. The inbox keeps
/// the highest cause of the events a merge or a collapse stands for.
@Suite struct EventCauseTests {
    private func renamed(_ mutationID: String?) -> DaemonEvent {
        let key = WorkspaceKey(rawValue: "w")
        let handle = WorkspaceHandle(rawValue: 1)
        return .workspaceRenamed(WorkspaceDelta(workspace: handle, index: nil, entity: WorkspaceSnapshot(id: handle, key: key, name: "n"),
                                                workspaceRevision: 2, origin: DaemonConnection.origin, mutationID: mutationID))
    }

    private func title(_ surface: UInt64, _ text: String, _ sequence: UInt64, _ cause: ObservationCause) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .titleChanged(surface: SurfaceID(rawValue: surface), title: text), cause: cause)
    }

    /// The `mutation_id` `connection.mutation()` gives inside `scope`.
    private func mutationID(in scope: DaemonCommandScope?, on connection: DaemonConnection) async -> String {
        await DaemonCommandScope.$current.withValue(scope) { await connection.mutation().mutationID }
    }

    private func makeConnection() -> DaemonConnection {
        DaemonConnection(endpointProvider: { throw DaemonError.notConnected })
    }

    @Test func theEchoOfAPersonRunsMutationIsPerson() async {
        let connection = makeConnection()
        let id = await mutationID(in: DaemonCommandScope.person(), on: connection)
        // The daemon calls the app's own request `frontend`; the app knows the person sent it.
        #expect(renamed(id).cause(wire: "frontend", recorded: connection.mutationCauses) == .person)
    }

    @Test func theEchoOfASocketRunsMutationIsAutomation() async {
        let connection = makeConnection()
        let id = await mutationID(in: DaemonCommandScope.automation(idempotencyKey: "key-1"), on: connection)
        #expect(renamed(id).cause(wire: "frontend", recorded: connection.mutationCauses) == .automation)
        // Derived from the key, so a retry with it replays and is still automation.
        #expect(id == DaemonCommandScope.derivedUUID(key: "key-1", kind: "mutation", ordinal: 1).uuidString.lowercased())
    }

    @Test func aMutationSentOutsideACausedScopeKeepsTheWireCause() async {
        let connection = makeConnection()
        let unscoped = await mutationID(in: nil, on: connection)
        let plain = await mutationID(in: DaemonCommandScope(), on: connection)
        #expect(renamed(unscoped).cause(wire: "frontend", recorded: connection.mutationCauses) == .frontend)
        #expect(renamed(plain).cause(wire: "automation", recorded: connection.mutationCauses) == .automation)
        #expect(connection.mutationCauses.count == 0)
    }

    @Test func anEchoOnAnotherConnectionIsNotMatched() async {
        let sender = makeConnection()
        let id = await mutationID(in: DaemonCommandScope.person(), on: sender)
        #expect(renamed(id).cause(wire: "frontend", recorded: makeConnection().mutationCauses) == .frontend)
    }

    @Test func theWireNamesFrontendAutomationAndProgram() {
        let ledger = MutationCauseLedger()
        #expect(renamed(nil).cause(wire: "frontend", recorded: ledger) == .frontend)
        #expect(renamed(nil).cause(wire: "automation", recorded: ledger) == .automation)
        #expect(renamed(nil).cause(wire: "program", recorded: ledger) == .program)
        // The wire never claims a person: only the app's own record does.
        #expect(renamed(nil).cause(wire: "person", recorded: ledger) == .program)
    }

    @Test func anOldDaemonsEventIsProgram() throws {
        let old = Data(#"{"event":"title-changed","surface":3,"title":"t"}"#.utf8)
        let envelope = try JSONDecoder().decode(LineTransport.Envelope.self, from: old)
        #expect(envelope.cause == nil)
        let event = DaemonEvent.decode(name: try #require(envelope.event), line: old)
        #expect(event.cause(wire: envelope.cause, recorded: MutationCauseLedger()) == .program)
        #expect(DaemonEventEnvelope(sequence: 1, event: event).cause == .program)
    }

    @Test func theEnvelopeCauseIsReadWithTheRoutingFields() throws {
        let line = Data(#"{"event":"title-changed","surface":3,"title":"t","cause":"automation"}"#.utf8)
        let envelope = try JSONDecoder().decode(LineTransport.Envelope.self, from: line)
        #expect(envelope.cause == "automation")
        // A reply's fields are never read as an event cause.
        let reply = try JSONDecoder().decode(LineTransport.Envelope.self, from: Data(#"{"id":1,"ok":true,"cause":"automation"}"#.utf8))
        #expect(reply.cause == nil)
    }

    @Test func aRecordedIdExpiresAfterTwoSeconds() {
        let clock = StillClock()
        let ledger = MutationCauseLedger(clock: clock)
        ledger.record("m", cause: .person)
        clock.advance(by: .milliseconds(1999))
        #expect(ledger.cause(of: "m") == .person)
        clock.advance(by: .milliseconds(1))
        #expect(ledger.cause(of: "m") == nil)
        #expect(renamed("m").cause(wire: "automation", recorded: ledger) == .automation)
    }

    @Test func theLedgerIsBounded() {
        let clock = StillClock()
        let ledger = MutationCauseLedger(clock: clock, capacity: 4)
        for index in 0..<10 { ledger.record("m\(index)", cause: .person) }
        #expect(ledger.count == 4)
        #expect(ledger.cause(of: "m5") == nil, "the oldest go first")
        #expect(ledger.cause(of: "m9") == .person)
        // Expired ids are dropped by the next record.
        clock.advance(by: .seconds(3))
        ledger.record("late", cause: .automation)
        #expect(ledger.count == 1)
    }

    private func tabClosed(_ transaction: ClientTransactionID?) -> DaemonEvent {
        let surface = SurfaceID(rawValue: 7)
        return .tabClosed(TabDelta(workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: PaneID(rawValue: 3),
                                   surface: surface, index: nil, entity: TabSnapshot(surface: surface), clientTransactionID: transaction))
    }

    /// Records the transaction `request` sends, as the connection's request funnel does, inside `scope`.
    private func send(_ request: some DaemonRequest, in scope: DaemonCommandScope?, on ledger: MutationCauseLedger) async {
        await DaemonCommandScope.$current.withValue(scope) { () async in DaemonCommandScope.recordEchoTransaction(of: request, in: ledger) }
    }

    @Test func aTabEchoOfAPersonRunIsPersonAndOfASocketRunIsAutomation() async {
        let ledger = MutationCauseLedger()
        let person = ClientTransactionID.generate(), socket = ClientTransactionID.generate()
        await send(CloseTabsRequest(surfaces: [SurfaceID(rawValue: 7)], endTerminals: true, transaction: person, mutation: nil),
                   in: DaemonCommandScope.person(), on: ledger)
        await send(CloseTabsRequest(surfaces: [SurfaceID(rawValue: 7)], endTerminals: true, transaction: socket, mutation: nil),
                   in: DaemonCommandScope.automation(idempotencyKey: "k"), on: ledger)
        #expect(tabClosed(person).cause(wire: "frontend", recorded: ledger) == .person)
        // The app's connection sent it, so the daemon says `frontend`; the socket run is automation.
        #expect(tabClosed(socket).cause(wire: "frontend", recorded: ledger) == .automation)
        #expect(tabClosed(.generate()).cause(wire: "frontend", recorded: ledger) == .frontend)
    }

    @Test func aLayoutEchoMatchesTheDecimalTransactionTheCommandSent() async {
        let ledger = MutationCauseLedger()
        let screen = ScreenID(rawValue: 2)
        await send(SetSplitRatioRequest(split: SplitID(rawValue: 5), ratio: 0.4, transaction: 41), in: DaemonCommandScope.person(), on: ledger)
        await send(SetSplitRatioRequest(split: SplitID(rawValue: 5), ratio: 0.6, transaction: 42),
                   in: DaemonCommandScope.automation(idempotencyKey: nil), on: ledger)
        let echo = { (transaction: String) in DaemonEvent.layoutChanged(screen: screen, layout: nil, transaction: ClientTransactionID(rawValue: transaction)) }
        #expect(echo("41").cause(wire: "frontend", recorded: ledger) == .person)
        #expect(echo("42").cause(wire: "frontend", recorded: ledger) == .automation)
        // A mutation id and a transaction with the same text are not the same record.
        #expect(renamed("41").cause(wire: "program", recorded: ledger) == .program)
    }

    @Test func aRequestOutsideACausedScopeRecordsNoTransaction() async {
        let ledger = MutationCauseLedger()
        let transaction = ClientTransactionID.generate()
        await send(MoveTabToSplitRequest(surface: SurfaceID(rawValue: 7), pane: PaneID(rawValue: 3), edge: .left, transaction: transaction),
                   in: nil, on: ledger)
        await send(MoveTabToSplitRequest(surface: SurfaceID(rawValue: 7), pane: PaneID(rawValue: 3), edge: .left, transaction: transaction),
                   in: DaemonCommandScope(), on: ledger)
        #expect(ledger.count == 0)
    }

    @Test func aStateMutationKeyIsRecordedAsTheEchoedMutationID() async {
        let connection = makeConnection()
        let key = await DaemonCommandScope.$current.withValue(DaemonCommandScope.person()) { () async in StateResourceClient.stateKey(on: connection) }
        #expect(renamed(key).cause(wire: "frontend", recorded: connection.mutationCauses) == .person)
    }

    @Test func aPersonScopeCreditsOnlyWhatItSendsWithinItsLifespan() {
        let clock = StillClock()
        let ledger = MutationCauseLedger(clock: clock)
        let scope = DaemonCommandScope.person(clock: clock)
        scope.recordMutation("soon", in: ledger)
        clock.advance(by: DaemonCommandScope.personLifespan)
        // A task the person's run started sends after the gesture's span: an ordinary command.
        scope.recordMutation("late", in: ledger)
        scope.recordTransaction(ClientTransactionID(rawValue: "late"), in: ledger)
        #expect(ledger.count == 1)
        #expect(renamed("late").cause(wire: "frontend", recorded: ledger) == .frontend)
        #expect(tabClosed(ClientTransactionID(rawValue: "late")).cause(wire: "automation", recorded: ledger) == .automation)
    }

    @Test func theAppAsksTheDaemonForTheEventCause() {
        let configuration = DaemonConnectionConfiguration(terminalEnvironment: nil)
        #expect(DaemonCapability.advertised.contains(DaemonCapability.eventCause.rawValue))
        #expect(configuration.handshakeCapabilities.contains(DaemonCapability.eventCause.rawValue))
    }

    @Test func aClosedScopeRecordsNothing() {
        let ledger = MutationCauseLedger()
        let scope = DaemonCommandScope.automation(idempotencyKey: nil)
        scope.close()
        scope.recordMutation("m", in: ledger)
        #expect(ledger.cause(of: "m") == nil)
    }

    @Test func aPersonScopeTracksNoCommands() {
        let scope = DaemonCommandScope.person()
        #expect(scope.begin(label: "x") == nil)
        scope.noteBarrier(9, machine: DaemonCommandScope.localMachine)
        scope.noteCreated([DaemonCreatedObject(.tab, "1")])
        #expect(scope.isIdle && scope.barriers.isEmpty && scope.created.isEmpty)
        #expect(scope.nextMutationID() == nil, "no key: a fresh id per mutation")
    }

    @Test func oneAutomationAndOnePersonEventOnOneSurfaceApplyAsPerson() {
        for order in [[ObservationCause.automation, .person], [.person, .automation]] {
            let inbox = EventInbox()
            _ = inbox.append(title(1, "a", 1, order[0]))
            _ = inbox.append(title(1, "b", 2, order[1]))
            let batch = inbox.take()
            #expect(batch.count == 1)
            #expect(batch.first?.cause == .person, "\(order)")
            #expect(batch.first.map { if case .titleChanged(_, let text) = $0.event { text } else { "" } } == "b")
        }
    }

    @Test func coalescingKeepsEachSurfacesOwnCause() {
        let inbox = EventInbox()
        _ = inbox.append(title(1, "a", 1, .person))
        _ = inbox.append(title(2, "x", 2, .automation))
        _ = inbox.append(title(2, "y", 3, .automation))
        #expect(inbox.take().map(\.cause) == [.person, .automation])
    }

    @Test func theOverflowResyncCarriesTheHighestDroppedCause() {
        let inbox = EventInbox(limit: 2)
        _ = inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil), cause: .automation))
        _ = inbox.append(DaemonEventEnvelope(sequence: 2, event: .personalChanged, cause: .person))
        _ = inbox.append(DaemonEventEnvelope(sequence: 3, event: .treeChanged(transaction: nil), cause: .automation))
        let batch = inbox.take()
        guard case .overflow = batch.first?.event else {
            Issue.record("the inbox did not collapse: \(batch)")
            return
        }
        #expect(batch.first?.cause == .person)
        // The next batch starts again from the lowest cause: an automation flood resyncs as automation.
        _ = inbox.append(DaemonEventEnvelope(sequence: 4, event: .treeChanged(transaction: nil), cause: .automation))
        _ = inbox.append(DaemonEventEnvelope(sequence: 5, event: .treeChanged(transaction: nil), cause: .automation))
        _ = inbox.append(DaemonEventEnvelope(sequence: 6, event: .treeChanged(transaction: nil), cause: .automation))
        #expect(inbox.take().first?.cause == .automation)
    }

    /// A page relay call (p06-scheduler-231): its key names the person only when a real event in the
    /// page backs it; a call without a key has no echo to match.
    @Test func aPageCallIsThePersonsOnlyWithAGestureAndAKey() {
        let ledger = MutationCauseLedger()
        ledger.recordPageCall("scripted", gestureBacked: false)
        ledger.recordPageCall(nil, gestureBacked: true)
        ledger.recordPageCall("typed", gestureBacked: true)
        #expect(ledger.count == 1)
        #expect(renamed("scripted").cause(wire: "automation", recorded: ledger) == .automation)
        #expect(renamed("typed").cause(wire: "automation", recorded: ledger) == .person)
    }

    @Test func aCollapsedInboxMergesPerSurfaceEventsWithTheirHighestCause() {
        let inbox = EventInbox(limit: 1)
        let surface = SurfaceID(rawValue: 4)
        _ = inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil)))
        _ = inbox.append(DaemonEventEnvelope(sequence: 2, event: .agentPresenceChanged(AgentPresence(surface: surface, activity: .editing)), cause: .person))
        _ = inbox.append(DaemonEventEnvelope(sequence: 3, event: .agentPresenceChanged(AgentPresence(surface: surface, activity: .editing)), cause: .automation))
        let presence = inbox.take().filter { if case .agentPresenceChanged = $0.event { true } else { false } }
        #expect(presence.map(\.sequence) == [3])
        #expect(presence.first?.cause == .person)
    }
}
