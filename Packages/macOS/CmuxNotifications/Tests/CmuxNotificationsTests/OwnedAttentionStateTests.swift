import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Owned attention state")
struct OwnedAttentionStateTests {
    @Test("Desired snapshots reject oversized content and destination lists")
    func bounds() throws {
        let epoch = UUID()
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: String(repeating: "x", count: 1025), body: "")
        #expect(throws: OwnedAttentionStateError.payloadTooLarge) {
            try OwnedAttentionState(epoch: epoch, revision: 1, destinations: [target])
        }
        let targets = (0..<257).map { _ in
            OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "a", body: "b")
        }
        #expect(throws: OwnedAttentionStateError.payloadTooLarge) {
            try OwnedAttentionState(epoch: epoch, revision: 1, destinations: targets)
        }
    }
    @Test("A newer revision replaces the complete desired projection")
    func replacement() throws {
        let epoch = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "1 waiting")
        let state = try OwnedAttentionState(epoch: epoch, revision: 1, destinations: [destination])
        let next = try state.applying(epoch: epoch, revision: 2, destinations: [])
        #expect(next.revision == 2)
        #expect(next.destinations.isEmpty)
    }

    @Test("Retries are idempotent and changed or stale revisions fail")
    func revisionOrdering() throws {
        let epoch = UUID()
        let state = try OwnedAttentionState(epoch: epoch, revision: 7, destinations: [])
        #expect(try state.applying(epoch: epoch, revision: 7, destinations: []) == state)
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "")
        #expect(throws: OwnedAttentionStateError.conflictingRevision) {
            try state.applying(epoch: epoch, revision: 7, destinations: [destination])
        }
        #expect(throws: OwnedAttentionStateError.staleRevision) {
            try state.applying(epoch: epoch, revision: 6, destinations: [destination])
        }
    }

    @Test("A fenced writer cannot replace current state")
    func writerFence() throws {
        let state = try OwnedAttentionState(epoch: UUID(), revision: 3, destinations: [])
        #expect(throws: OwnedAttentionStateError.wrongEpoch) {
            try state.applying(epoch: UUID(), revision: 4, destinations: [])
        }
    }

    @Test("Initialization and decoding reject duplicate destinations")
    func duplicateDestinations() throws {
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "")
        #expect(throws: OwnedAttentionStateError.duplicateDestination) {
            try OwnedAttentionState(epoch: UUID(), revision: 1, destinations: [destination, destination])
        }
        let encodedDestination = try JSONEncoder().encode(destination)
        let json = "{\"epoch\":\"\(UUID().uuidString)\",\"revision\":1,\"destinations\":[\(String(decoding: encodedDestination, as: UTF8.self)),\(String(decoding: encodedDestination, as: UTF8.self))]}"
        #expect(throws: OwnedAttentionStateError.duplicateDestination) {
            try JSONDecoder().decode(OwnedAttentionState.self, from: Data(json.utf8))
        }
    }

    @Test("Destination order does not change state or retry identity")
    func canonicalOrder() throws {
        let epoch = UUID()
        let first = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "first", body: "")
        let second = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "second", body: "")
        let state = try OwnedAttentionState(epoch: epoch, revision: 1, destinations: [first, second])
        let reversed = try OwnedAttentionState(epoch: epoch, revision: 1, destinations: [second, first])
        #expect(state == reversed)
        #expect(try state.applying(epoch: epoch, revision: 1, destinations: [second, first]) == state)
        let decoded = try JSONDecoder().decode(OwnedAttentionState.self, from: JSONEncoder().encode(reversed))
        #expect(decoded == state)
    }
}
