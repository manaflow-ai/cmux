import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Owned attention commands")
struct OwnedAttentionCommandTests {
    @Test("Updates preserve unavailable unchanged destinations while updating authorized ones")
    func preservesUnavailableDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity()
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let unavailable = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let available = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Done", body: "")
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        try repository.apply(producer: producer, capability: capability, epoch: epoch, revision: 1, destinations: [unavailable])
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID) { _, destination in
            destination.workspaceID == available.workspaceID
        }
        let command = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "2", destinations: [unavailable, available])
        _ = try handler.handle(JSONEncoder().encode(command))
        let state = try #require(try repository.read(producer: producer, capability: capability))
        #expect(Set(state.destinations.map(\.workspaceID)) == Set([unavailable.workspaceID, available.workspaceID]))
        let changed = OwnedAttentionDestination(workspaceID: unavailable.workspaceID, surfaceID: unavailable.surfaceID, title: "Changed", body: "")
        let denied = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "3", destinations: [changed, available])
        #expect(throws: OwnedAttentionCommandError.targetDenied) { try handler.handle(JSONEncoder().encode(denied)) }
        #expect(try repository.read(producer: producer, capability: capability)?.revision == 2)
    }
    @Test("An unavailable destination removed concurrently cannot be restored without authorization")
    func unavailableDestinationRemovedConcurrently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        try repository.apply(producer: producer, capability: capability, epoch: epoch, revision: 1, destinations: [target])
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity()) { _, _ in
            try? repository.apply(producer: producer, capability: capability, epoch: epoch, revision: 2, destinations: [])
            return false
        }
        let command = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "3", destinations: [target])
        #expect(throws: OwnedAttentionCommandError.targetDenied) { try handler.handle(JSONEncoder().encode(command)) }
        let state = try #require(try repository.read(producer: producer, capability: capability))
        #expect(state.revision == 2)
        #expect(state.destinations.isEmpty)
    }
    @Test("Envelope handler rejects a missing or mismatched store identity")
    func rejectsInvalidEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity()
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID, authorizeDestination: { _, _ in true })
        let command = OwnedAttentionCommand.register(producer: UUID(), capability: Data(repeating: 7, count: 32), epoch: UUID())
        #expect(throws: (any Error).self) { try handler.handleEnvelope(JSONEncoder().encode(command)) }
        let wrong = OwnedAttentionCommandEnvelope(storeID: UUID(), command: command)
        #expect(throws: OwnedAttentionCommandError.storeMismatch) { try handler.handleEnvelope(JSONEncoder().encode(wrong)) }
        let correct = OwnedAttentionCommandEnvelope(storeID: storeID, command: command)
        #expect(try handler.handleEnvelope(JSONEncoder().encode(correct)).projectionRequired)
    }
    @Test("The wire request carries the producer's expected store identity")
    func wireStoreIdentity() throws {
        let storeID = UUID(), producer = UUID(), capability = Data(repeating: 7, count: 32)
        let envelope = OwnedAttentionCommandEnvelope(storeID: storeID, command: .read(producer: producer, capability: capability))
        let data = try JSONEncoder().encode(envelope)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["store_id"] as? String == storeID.uuidString)
        let decoded = try JSONDecoder().decode(OwnedAttentionCommandEnvelope.self, from: data)
        #expect(decoded.storeID == storeID)
    }
    @Test("Commands reject a replaced register before registration")
    func rejectsReplacedRegister() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("old.sqlite3"), create: true)
        let replacement = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("new.sqlite3"), create: true)
        let expectedID = try original.projectionSnapshot().storeID
        let handler = OwnedAttentionCommandHandler(repository: replacement, expectedStoreID: expectedID, authorizeDestination: { _, _ in true })
        let command = OwnedAttentionCommand.register(producer: UUID(), capability: Data(repeating: 7, count: 32), epoch: UUID())
        #expect(throws: OwnedAttentionCommandError.storeMismatch) { try handler.handle(JSONEncoder().encode(command)) }
        #expect(try replacement.projectionSnapshot().states.isEmpty)
    }
    @Test("Updates cannot publish to destinations outside the producer binding")
    func rejectsUnboundTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity(), authorizeDestination: { _, _ in false })
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        _ = try handler.handle(JSONEncoder().encode(OwnedAttentionCommand.register(producer: producer, capability: capability, epoch: epoch)))
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let command = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [destination])
        #expect(throws: OwnedAttentionCommandError.targetDenied) { try handler.handle(JSONEncoder().encode(command)) }
        let wrong = OwnedAttentionCommand.set(producer: producer, capability: Data(repeating: 8, count: 32), epoch: epoch, revision: "1", destinations: [destination])
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) { try handler.handle(JSONEncoder().encode(wrong)) }
        #expect(try repository.read(producer: producer, capability: capability)?.revision == 0)
    }
    @Test("A committed retry succeeds when its destination has disappeared")
    func retryAfterDestinationDisappears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity()
        let accepting = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID, authorizeDestination: { _, _ in true })
        let denying = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID, authorizeDestination: { _, _ in false })
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        _ = try accepting.handle(JSONEncoder().encode(OwnedAttentionCommand.register(producer: producer, capability: capability, epoch: epoch)))
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let update = try JSONEncoder().encode(OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [target]))
        _ = try accepting.handle(update)
        #expect(try denying.handle(update).projectionRequired)
    }
    @Test("A concurrent commit is recognized after destination authorization fails")
    func concurrentCommitBeforeAuthorizationFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity()) { _, _ in
            try? repository.apply(producer: producer, capability: capability, epoch: epoch, revision: 1, destinations: [target])
            return false
        }
        let update = try JSONEncoder().encode(OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [target]))
        #expect(try handler.handle(update).projectionRequired)
    }
    @Test("Authorization failure does not overwrite a concurrent newer update")
    func authorizationFailureAfterNewerCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity()) { _, _ in
            try? repository.apply(producer: producer, capability: capability, epoch: epoch, revision: 2, destinations: [])
            return false
        }
        let update = try JSONEncoder().encode(OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [target]))
        #expect(throws: OwnedAttentionStateError.staleRevision) { try handler.handle(update) }
        let state = try #require(try repository.read(producer: producer, capability: capability))
        #expect(state.revision == 2)
        #expect(state.destinations.isEmpty)
    }
    @Test("Authorization failure cannot overwrite a concurrent conflicting update")
    func authorizationFailureAfterConflictingCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity()) { _, _ in
            try? repository.apply(producer: producer, capability: capability, epoch: epoch, revision: 1, destinations: [])
            return false
        }
        let update = try JSONEncoder().encode(OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [target]))
        #expect(throws: OwnedAttentionStateError.conflictingRevision) { try handler.handle(update) }
        let state = try #require(try repository.read(producer: producer, capability: capability))
        #expect(state.revision == 1)
        #expect(state.destinations.isEmpty)
    }
    @Test("Authorization failure cannot overwrite a concurrent resumed writer")
    func authorizationFailureAfterResume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity()) { _, _ in
            _ = try? repository.resume(producer: producer, capability: capability, expectedEpoch: epoch, requestID: UUID())
            return false
        }
        let update = try JSONEncoder().encode(OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [target]))
        #expect(throws: OwnedAttentionStateError.wrongEpoch) { try handler.handle(update) }
        let state = try #require(try repository.read(producer: producer, capability: capability))
        #expect(state.epoch != epoch)
        #expect(state.destinations.isEmpty)
    }
    @Test("Command wire payload uses a flat action and decimal revision")
    func wireFormat() throws {
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let command = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "18446744073709551615", destinations: [destination])
        let data = try JSONEncoder().encode(command)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["action"] as? String == "set")
        #expect(object["producer"] as? String == producer.uuidString)
        #expect(object["revision"] as? String == "18446744073709551615")
        let destinations = try #require(object["destinations"] as? [[String: Any]])
        #expect(destinations.first?["workspace_id"] as? String == destination.workspaceID.uuidString)
        #expect(destinations.first?["surface_id"] as? String == destination.surfaceID.uuidString)
        let decoded = try JSONDecoder().decode(OwnedAttentionCommand.self, from: data)
        if case let .set(decodedProducer, decodedCapability, decodedEpoch, revision, _) = decoded {
            #expect(decodedProducer == producer)
            #expect(decodedCapability == capability)
            #expect(decodedEpoch == epoch)
            #expect(revision == "18446744073709551615")
        } else {
            Issue.record("incorrect decoded action")
        }
    }
    @Test("Authorized register, set, and read preserve committed state")
    func authorizedRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity(), authorizeDestination: { _, _ in true })
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        let register = OwnedAttentionCommand.register(producer: producer, capability: capability, epoch: epoch)
        let registered = try handler.handle(JSONEncoder().encode(register))
        #expect(registered.state == nil)
        #expect(registered.projectionRequired)
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let set = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [destination])
        #expect(try handler.handle(JSONEncoder().encode(set)).projectionRequired)
        #expect(try handler.handle(JSONEncoder().encode(set)).projectionRequired)
        let read = OwnedAttentionCommand.read(producer: producer, capability: capability)
        let result = try handler.handle(JSONEncoder().encode(read))
        #expect(result.state?.destinations == [destination])
        #expect(!result.projectionRequired)
        let wrong = OwnedAttentionCommand.read(producer: producer, capability: Data(repeating: 8, count: 32))
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) { try handler.handle(JSONEncoder().encode(wrong)) }
    }

    @Test("Oversized requests are rejected before decoding")
    func oversizedRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity(), authorizeDestination: { _, _ in true })
        #expect(throws: OwnedAttentionCommandError.requestTooLarge) {
            try handler.handle(Data(repeating: 32, count: OwnedAttentionCommandHandler.maximumRequestBytes + 1))
        }
    }

    @Test("Revision strings are canonical and overflow is rejected")
    func revisionValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity(), authorizeDestination: { _, _ in true })
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        _ = try handler.handle(JSONEncoder().encode(OwnedAttentionCommand.register(producer: producer, capability: capability, epoch: epoch)))
        for invalid in ["01", "-1", "+1", "18446744073709551616", ""] {
            let command = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: invalid, destinations: [])
            #expect(throws: OwnedAttentionCommandError.invalidRevision) { try handler.handle(JSONEncoder().encode(command)) }
        }
        #expect(try repository.read(producer: producer, capability: capability)?.revision == 0)
    }

    @Test("Read responses preserve the full unsigned revision as a decimal string")
    func responseRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32)
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        try repository.apply(producer: producer, capability: capability, epoch: epoch, revision: .max, destinations: [])
        let result = try OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity(), authorizeDestination: { _, _ in true }).handle(JSONEncoder().encode(OwnedAttentionCommand.read(producer: producer, capability: capability)))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let state = try #require(object["state"] as? [String: Any])
        #expect(state["revision"] as? String == "18446744073709551615")
    }

    @Test("Writer takeover retries preserve state and fence old commands")
    func resumeRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: try repository.storeIdentity(), authorizeDestination: { _, _ in true })
        let producer = UUID(), epoch = UUID(), capability = Data(repeating: 7, count: 32), requestID = UUID()
        _ = try handler.handle(JSONEncoder().encode(OwnedAttentionCommand.register(producer: producer, capability: capability, epoch: epoch)))
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        _ = try handler.handle(JSONEncoder().encode(OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [destination])))
        let resume = try JSONEncoder().encode(OwnedAttentionCommand.resume(producer: producer, capability: capability, expectedEpoch: epoch, requestID: requestID))
        let first = try #require(handler.handle(resume).state)
        #expect(try handler.handle(resume).state == first)
        #expect(first.destinations == [destination])
        let stale = OwnedAttentionCommand.set(producer: producer, capability: capability, epoch: epoch, revision: "2", destinations: [])
        #expect(throws: OwnedAttentionStateError.wrongEpoch) { try handler.handle(JSONEncoder().encode(stale)) }
    }
}
