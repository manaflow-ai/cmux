import Foundation
import Testing
@testable import CmuxNotifications

private func waitForLeaseTest(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
}

@Suite("Owned attention connection leases")
struct OwnedAttentionLeaseTests {
    @Test("A producer belongs to one live connection")
    func ownershipAndRelease() async {
        let leases = OwnedAttentionLeases()
        let producer = UUID(), first = UUID(), second = UUID(), other = UUID()
        #expect(leases.acquire(producer: producer, connection: first))
        #expect(leases.acquire(producer: producer, connection: first))
        #expect(!(leases.acquire(producer: producer, connection: second)))
        #expect(leases.acquire(producer: other, connection: second))
        leases.release(connection: first)
        #expect(leases.acquire(producer: producer, connection: second))
        leases.release(connection: first)
        #expect(!(leases.acquire(producer: producer, connection: first)))
    }

    @Test("Commands authenticate before taking a connection lease")
    func authenticatedCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity()
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID, authorizeDestination: { _, _ in true })
        let leases = OwnedAttentionLeases()
        let producer = UUID(), epoch = UUID(), first = UUID(), second = UUID()
        let secret = Data(repeating: 7, count: 32)
        let registration = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .register(producer: producer, capability: secret, epoch: epoch)))
        _ = try leases.handle(registration, connection: first, repository: repository, handler: handler)
        let wrong = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .read(producer: producer, capability: Data(repeating: 8, count: 32))))
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) {
            try leases.handle(wrong, connection: second, repository: repository, handler: handler)
        }
        let read = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .read(producer: producer, capability: secret)))
        #expect(throws: OwnedAttentionCommandError.leaseHeld) {
            try leases.handle(read, connection: second, repository: repository, handler: handler)
        }
        leases.release(connection: first)
        #expect(try leases.handle(read, connection: second, repository: repository, handler: handler).state != nil)
    }

    @Test("An unauthenticated connection cannot reserve an unowned producer")
    func wrongSecretCannotReserve() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity(), producer = UUID(), epoch = UUID()
        let secret = Data(repeating: 7, count: 32)
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID, authorizeDestination: { _, _ in true })
        let leases = OwnedAttentionLeases()
        let wrong = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .read(producer: producer, capability: Data(repeating: 8, count: 32))))
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) {
            try leases.handle(wrong, connection: UUID(), repository: repository, handler: handler)
        }
        let read = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .read(producer: producer, capability: secret)))
        #expect(try leases.handle(read, connection: UUID(), repository: repository, handler: handler).state != nil)
    }

    @Test("Successful updates return a projection snapshot on the same lease")
    func updateReturnsProjectionSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity(), producer = UUID(), epoch = UUID(), connection = UUID()
        let secret = Data(repeating: 7, count: 32)
        let leases = OwnedAttentionLeases()
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID, authorizeDestination: { _, _ in true })
        let register = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .register(producer: producer, capability: secret, epoch: epoch)))
        _ = try leases.execute(register, connection: connection, repository: repository, handler: handler)
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let update = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .set(producer: producer, capability: secret, epoch: epoch, revision: "1", destinations: [target])))
        let execution = try leases.execute(update, connection: connection, repository: repository, handler: handler)
        let snapshot = try #require(execution.snapshot)
        #expect(snapshot.states[producer]?.destinations == [target])
        #expect(execution.result.projectionRequired)
    }

    @Test("Concurrent connections cannot both own a producer")
    func simultaneousAcquisition() async {
        let leases = OwnedAttentionLeases()
        let producer = UUID()
        let successful = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    leases.acquire(producer: producer, connection: UUID())
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(successful == 1)
    }

    @Test("Disconnect waits for a command already in progress")
    func releaseDuringCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let storeID = try repository.storeIdentity()
        let producer = UUID(), epoch = UUID(), connection = UUID()
        let capability = Data(repeating: 7, count: 32)
        try repository.register(producer: producer, capability: capability, epoch: epoch)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let handler = OwnedAttentionCommandHandler(repository: repository, expectedStoreID: storeID) { _, _ in
            entered.signal()
            resume.wait()
            return true
        }
        let target = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let data = try JSONEncoder().encode(OwnedAttentionCommandEnvelope(storeID: storeID, command: .set(producer: producer, capability: capability, epoch: epoch, revision: "1", destinations: [target])))
        let leases = OwnedAttentionLeases()
        let command = Task.detached { try leases.handle(data, connection: connection, repository: repository, handler: handler) }
        #expect(await Task.detached { waitForLeaseTest(entered) }.value)
        let release = Task.detached { leases.release(connection: connection) }
        resume.signal()
        _ = try await command.value
        await release.value
        #expect(leases.acquire(producer: producer, connection: UUID()))
    }
}
