import Foundation
import Testing
@testable import CmuxAgentReplica

@Suite struct TicketLedgerClientTests {
    @Test func legalTransitionsApplyAndIllegalTransitionsAreCounted() {
        let id = UUID()
        var ledger = TicketLedgerClient()
        let queuedApplied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .queuedLocal, createdAt: 1))
        let acceptedApplied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .acceptedByMac, createdAt: 1))
        let injectedApplied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .injected, createdAt: 1))
        let echoedApplied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .echoed(ReplicaTestSupport.seq(7)), createdAt: 1))

        let illegalApplied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .acceptedByMac, createdAt: 1))
        #expect(queuedApplied)
        #expect(acceptedApplied)
        #expect(injectedApplied)
        #expect(echoedApplied)
        #expect(!illegalApplied)
        #expect(ledger.illegalTransitionCount == 1)
        #expect(ledger.tickets.first?.state == .echoed(ReplicaTestSupport.seq(7)))
    }

    @Test func skipAheadFromQueuedLocalToEchoedApplies() {
        let id = UUID()
        var ledger = TicketLedgerClient()
        _ = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .queuedLocal, createdAt: 1))

        let applied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .echoed(ReplicaTestSupport.seq(9)), createdAt: 1))

        #expect(applied)
        #expect(ledger.tickets.first?.state == .echoed(ReplicaTestSupport.seq(9)))
        #expect(ledger.illegalTransitionCount == 0)
    }

    @Test func echoedResolvesOldestUnresolvedMatchingTicket() {
        let id = UUID()
        var ledger = TicketLedgerClient(tickets: [
            ReplicaTestSupport.ticket(id: id, state: .acceptedByMac, createdAt: 1),
            ReplicaTestSupport.ticket(id: id, state: .queuedLocal, createdAt: 2),
        ])

        let applied = ledger.apply(ReplicaTestSupport.ticket(id: id, state: .echoed(ReplicaTestSupport.seq(4)), createdAt: 2))

        #expect(applied)
        #expect(ledger.tickets.map(\.state) == [.echoed(ReplicaTestSupport.seq(4)), .queuedLocal])
    }

    @Test func fifoDedupKeepsCreationOrder() {
        let later = UUID()
        let earlier = UUID()
        var ledger = TicketLedgerClient()
        _ = ledger.apply(ReplicaTestSupport.ticket(id: later, state: .queuedLocal, createdAt: 20))
        _ = ledger.apply(ReplicaTestSupport.ticket(id: earlier, state: .queuedLocal, createdAt: 10))
        _ = ledger.apply(ReplicaTestSupport.ticket(id: earlier, state: .acceptedByMac, createdAt: 10))

        #expect(ledger.tickets.map(\.id) == [earlier, later])
        #expect(ledger.tickets.count == 2)
    }
}
