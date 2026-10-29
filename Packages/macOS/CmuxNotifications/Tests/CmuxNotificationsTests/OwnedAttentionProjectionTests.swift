import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Owned attention projection")
struct OwnedAttentionProjectionTests {
    @Test("An owned row cannot reuse an unrelated notification identity")
    func rejectsIdentityCollisions() throws {
        let producer = UUID(), identity = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let target = OwnedAttentionTarget(workspaceID: destination.workspaceID, surfaceID: destination.surfaceID)
        let slot = OwnedAttentionSlot(producerID: producer, target: target)
        let state = try OwnedAttentionState(epoch: UUID(), revision: 1, destinations: [destination])
        let plan = OwnedAttentionProjection.plan(states: [producer: state], unavailable: [], muted: [], foreignUnread: [])
        #expect(throws: OwnedAttentionProjectionError.identityCollision) {
            try plan.validateIdentities([slot: identity], foreignIDs: [identity])
        }
        #expect(throws: OwnedAttentionProjectionError.missingIdentity) {
            try plan.validateIdentities([:], foreignIDs: [])
        }
        try plan.validateIdentities([slot: identity], foreignIDs: [])
    }
    @Test("Unavailable and muted targets retain their distinct status")
    func unavailableAndMuted() throws {
        let producer = UUID()
        let first = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "first", body: "")
        let second = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "second", body: "")
        let firstTarget = OwnedAttentionTarget(workspaceID: first.workspaceID, surfaceID: first.surfaceID)
        let secondTarget = OwnedAttentionTarget(workspaceID: second.workspaceID, surfaceID: second.surfaceID)
        let state = try OwnedAttentionState(epoch: UUID(), revision: 1, destinations: [first, second])
        let plan = OwnedAttentionProjection.plan(states: [producer: state], unavailable: [firstTarget], muted: [secondTarget], foreignUnread: [])
        #expect(plan.rows.isEmpty)
        #expect(plan.statuses[OwnedAttentionSlot(producerID: producer, target: firstTarget)] == .targetUnavailable)
        #expect(plan.statuses[OwnedAttentionSlot(producerID: producer, target: secondTarget)] == .muted)
    }
    @Test("Foreign unread defers owned attention without losing desired state")
    func foreignUnread() throws {
        let producer = UUID(), workspace = UUID(), surface = UUID()
        let destination = OwnedAttentionDestination(workspaceID: workspace, surfaceID: surface, title: "Waiting", body: "")
        let state = try OwnedAttentionState(epoch: UUID(), revision: 1, destinations: [destination])
        let target = OwnedAttentionTarget(workspaceID: workspace, surfaceID: surface)
        let deferred = OwnedAttentionProjection.plan(states: [producer: state], unavailable: [], muted: [], foreignUnread: [target])
        #expect(deferred.rows.isEmpty)
        #expect(deferred.statuses[OwnedAttentionSlot(producerID: producer, target: target)] == .deferredForeignUnread)
        let visible = OwnedAttentionProjection.plan(states: [producer: state], unavailable: [], muted: [], foreignUnread: [])
        #expect(visible.rows[OwnedAttentionSlot(producerID: producer, target: target)] == destination)
    }

    @Test("Competing producers use stable admission and withdrawal admits the next")
    func competingProducers() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let target = OwnedAttentionTarget(workspaceID: destination.workspaceID, surfaceID: destination.surfaceID)
        let active = try OwnedAttentionState(epoch: UUID(), revision: 1, destinations: [destination])
        let empty = try OwnedAttentionState(epoch: UUID(), revision: 2, destinations: [])
        let firstSlot = OwnedAttentionSlot(producerID: first, target: target)
        let secondSlot = OwnedAttentionSlot(producerID: second, target: target)
        let both = OwnedAttentionProjection.plan(states: [second: active, first: active], unavailable: [], muted: [], foreignUnread: [])
        #expect(both.rows[firstSlot] == destination)
        #expect(both.statuses[secondSlot] == .deferredForeignUnread)
        let withdrawn = OwnedAttentionProjection.plan(states: [second: active, first: empty], unavailable: [], muted: [], foreignUnread: [])
        #expect(withdrawn.rows[firstSlot] == nil)
        #expect(withdrawn.rows[secondSlot] == destination)
    }
}
