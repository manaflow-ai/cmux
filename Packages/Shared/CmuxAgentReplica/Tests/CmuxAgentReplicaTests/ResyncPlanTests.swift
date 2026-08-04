import Foundation
import Testing
@testable import CmuxAgentReplica

@Suite struct ResyncPlanTests {
    @Test func sameEpochReconnectWithGapPullsOnlyGapConversationThenFlushesTickets() {
        let id = UUID()
        let plan = ResyncPlan.make(
            cachedEpoch: ReplicaEpoch(rawValue: "e1"),
            helloEpoch: ReplicaEpoch(rawValue: "e1"),
            openConversations: [
                ResyncConversationState(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, needsTailPull: true),
                ResyncConversationState(sessionID: ReplicaTestSupport.otherSession, journalID: ReplicaTestSupport.otherJournal, needsTailPull: false),
            ],
            ticketQueue: [ReplicaTestSupport.ticket(id: id, state: .queuedLocal, createdAt: 1)]
        )

        #expect(plan.steps == [.keepState, .pullSessions, .pullTailPage(ReplicaTestSupport.session), .flushTickets])
    }

    @Test func journalRotationMidStreamPullsTailForConversationWithGap() {
        let plan = ResyncPlan.make(
            cachedEpoch: ReplicaEpoch(rawValue: "e1"),
            helloEpoch: ReplicaEpoch(rawValue: "e1"),
            openConversations: [
                ResyncConversationState(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.otherJournal, needsTailPull: true),
            ],
            ticketQueue: []
        )

        #expect(plan.steps == [.keepState, .pullSessions, .pullTailPage(ReplicaTestSupport.session)])
    }

    @Test func macRelaunchDropsAllThenPullsEveryOpenConversationAndFlushesTickets() {
        let id = UUID()
        let plan = ResyncPlan.make(
            cachedEpoch: ReplicaEpoch(rawValue: "e1"),
            helloEpoch: ReplicaEpoch(rawValue: "e2"),
            openConversations: [
                ResyncConversationState(sessionID: ReplicaTestSupport.otherSession, journalID: nil, needsTailPull: false),
                ResyncConversationState(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, needsTailPull: false),
            ],
            ticketQueue: [ReplicaTestSupport.ticket(id: id, state: .queuedLocal, createdAt: 1)]
        )

        #expect(plan.steps == [.dropAll, .pullSessions, .pullTailPage(ReplicaTestSupport.session), .pullTailPage(ReplicaTestSupport.otherSession), .flushTickets])
    }

    @Test func duplicateReorderedDeltasDuringInflightPullKeepStateAndDoNotAddTailPulls() {
        let plan = ResyncPlan.make(
            cachedEpoch: ReplicaEpoch(rawValue: "e1"),
            helloEpoch: ReplicaEpoch(rawValue: "e1"),
            openConversations: [
                ResyncConversationState(sessionID: ReplicaTestSupport.session, journalID: ReplicaTestSupport.journal, needsTailPull: false),
            ],
            ticketQueue: []
        )

        #expect(plan.steps == [.keepState, .pullSessions])
    }
}
