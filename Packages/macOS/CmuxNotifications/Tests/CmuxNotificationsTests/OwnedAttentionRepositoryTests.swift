import Foundation
import SQLite3
import Testing
@testable import CmuxNotifications

private final class ProvisionAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@Suite("Owned attention repository")
struct OwnedAttentionRepositoryTests {
    private let secret = Data(repeating: 42, count: 32)

    @Test("Store provider retries failures and caches only a successful open")
    func providerRetries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let attempts = ProvisionAttempts()
        let provider = OwnedAttentionRepositoryProvider {
            guard attempts.next() > 1 else { throw OwnedAttentionRepositoryError.storage("temporary") }
            return try OwnedAttentionRepository.openOrProvision(databaseURL: url)
        }
        #expect(throws: OwnedAttentionRepositoryError.storage("temporary")) { try provider.repository() }
        let first = try provider.repository()
        let second = try provider.repository()
        #expect(first === second)
    }

    @Test("Opening or provisioning preserves the same store identity")
    func openOrProvision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let first = try OwnedAttentionRepository.openOrProvision(databaseURL: url)
        let second = try OwnedAttentionRepository.openOrProvision(databaseURL: url)
        #expect(try first.storeIdentity() == second.storeIdentity())
    }

    @Test("Opening or provisioning refuses an existing corrupt store")
    func refusesCorruptProvisionedStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        try Data("corrupt".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository.openOrProvision(databaseURL: url) }
        #expect(try Data(contentsOf: url) == Data("corrupt".utf8))
    }

    @Test("Opening a register with missing metadata fails")
    func refusesMissingMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        do { _ = try OwnedAttentionRepository(databaseURL: url, create: true) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DELETE FROM owned_attention_metadata", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository.openOrProvision(databaseURL: url) }
    }

    @Test("Concurrent provisioners never return different store identities")
    func concurrentProvisioning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let identities = await withTaskGroup(of: UUID?.self, returning: [UUID].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    guard let store = try? OwnedAttentionRepository.openOrProvision(databaseURL: url) else { return nil }
                    return try? store.storeIdentity()
                }
            }
            var values: [UUID] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }
        #expect(!identities.isEmpty)
        #expect(Set(identities).count == 1)
        let reopened = try OwnedAttentionRepository.openOrProvision(databaseURL: url)
        #expect(try reopened.storeIdentity() == identities.first)
    }

    @Test("A newly provisioned register has a different durable identity")
    func registerIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let original: UUID
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            original = try repository.projectionSnapshot().storeID
        }
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: false)
            #expect(try repository.projectionSnapshot().storeID == original)
        }
        let replacement = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("replacement.sqlite3"), create: true)
        #expect(try replacement.projectionSnapshot().storeID != original)
    }

    @Test("Generation exhaustion rolls back the state update and identity allocation")
    func generationExhaustion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "UPDATE owned_attention_metadata SET generation = 9223372036854775807", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        #expect(throws: (any Error).self) {
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [destination])
        }
        let snapshot = try repository.projectionSnapshot()
        #expect(snapshot.states[producer]?.revision == 0)
        #expect(snapshot.identities.isEmpty)
        #expect(snapshot.generation == Int64.max)
    }

    @Test("Projection snapshots carry a durable monotonic generation")
    func snapshotGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        var previous: Int64 = -1
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            previous = try repository.projectionSnapshot().generation
            try repository.register(producer: producer, capability: secret, epoch: epoch)
            let registered = try repository.projectionSnapshot().generation
            #expect(registered > previous)
            try repository.register(producer: producer, capability: secret, epoch: epoch)
            #expect(try repository.projectionSnapshot().generation == registered)
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [])
            previous = try repository.projectionSnapshot().generation
            #expect(previous > registered)
        }
        let reopened = try OwnedAttentionRepository(databaseURL: url, create: false)
        #expect(try reopened.projectionSnapshot().generation == previous)
        _ = try reopened.resume(producer: producer, capability: secret, expectedEpoch: epoch, requestID: UUID())
        #expect(try reopened.projectionSnapshot().generation > previous)
    }

    @Test("Registration quota preserves existing producers and permits retries")
    func registrationQuota() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID()
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        for _ in 1..<256 {
            try repository.register(producer: UUID(), capability: secret, epoch: UUID())
        }
        #expect(throws: OwnedAttentionRepositoryError.producerQuotaExceeded) {
            try repository.register(producer: UUID(), capability: secret, epoch: UUID())
        }
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        #expect(try repository.read(producer: producer, capability: secret)?.epoch == epoch)
    }

    @Test("Identity history quota rejects a new slot without changing the committed state")
    func identityQuota() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let sql = "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<4096) INSERT INTO owned_attention_identity SELECT '\(producer.uuidString)', printf('%08X-0000-0000-0000-%012X',x,x), printf('%08X-0000-0000-0001-%012X',x,x), printf('%08X-0000-0000-0002-%012X',x,x) FROM n"
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let new = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        #expect(throws: OwnedAttentionRepositoryError.identityQuotaExceeded) {
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [new])
        }
        #expect(try repository.read(producer: producer, capability: secret)?.revision == 0)
    }

    @Test("A missing committed projection identity fails closed")
    func missingIdentityFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            try repository.register(producer: producer, capability: secret, epoch: epoch)
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [destination])
        }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DELETE FROM owned_attention_identity", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let repository = try OwnedAttentionRepository(databaseURL: url, create: false)
        #expect(throws: (any Error).self) { try repository.projectionSnapshot() }
        #expect(throws: (any Error).self) {
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 2, destinations: [destination])
        }
        #expect(try repository.read(producer: producer, capability: secret)?.revision == 1)
    }

    @Test("Projection identities survive updates, withdrawal, and reopening")
    func stableProjectionIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "Waiting", body: "")
        let slot = OwnedAttentionSlot(producerID: producer, target: OwnedAttentionTarget(workspaceID: destination.workspaceID, surfaceID: destination.surfaceID))
        var identity: UUID?
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            try repository.register(producer: producer, capability: secret, epoch: epoch)
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [destination])
            identity = try #require(repository.projectionSnapshot().identities[slot])
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 2, destinations: [])
        }
        let reopened = try OwnedAttentionRepository(databaseURL: url, create: false)
        try reopened.apply(producer: producer, capability: secret, epoch: epoch, revision: 3, destinations: [destination])
        #expect(try reopened.projectionSnapshot().identities[slot] == identity)
    }

    @Test("Projection reads committed state while another connection holds a write transaction")
    func snapshotDuringWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
        let producer = UUID(), epoch = UUID()
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        #expect(try repository.projectionSnapshot().states[producer]?.epoch == epoch)
    }

    @Test("Registration can be retried without resetting committed state")
    func retryRegistration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "")
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [destination])
        try repository.register(producer: producer, capability: secret, epoch: epoch)
        #expect(try repository.read(producer: producer, capability: secret)?.destinations == [destination])
        #expect(throws: (any Error).self) {
            try repository.register(producer: producer, capability: Data(repeating: 7, count: 32), epoch: epoch)
        }
        let next = try repository.resume(producer: producer, capability: secret, expectedEpoch: epoch, requestID: UUID())
        #expect(next.epoch != epoch)
        #expect(throws: (any Error).self) { try repository.register(producer: producer, capability: secret, epoch: epoch) }
    }

    @Test("A restrictive ancestor ACL does not prevent normal storage")
    func permitsDenyOnlyAncestorACL() throws {
        let ancestor = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        let directory = ancestor.appendingPathComponent("register", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ancestor) }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone deny delete", ancestor.path]
        try command.run()
        command.waitUntilExit()
        #expect(command.terminationStatus == 0)
        _ = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
    }

    @Test("An unsafe ancestor cannot replace the register directory")
    func rejectsWritableAncestor() throws {
        let ancestor = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        let directory = ancestor.appendingPathComponent("register", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ancestor) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: ancestor.path)
        let url = directory.appendingPathComponent("state.sqlite3")
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: true) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A reopened register provides a consistent snapshot for projection")
    func snapshotForProjection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let first = UUID(), second = UUID(), firstEpoch = UUID(), secondEpoch = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "")
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            try repository.register(producer: first, capability: secret, epoch: firstEpoch)
            try repository.register(producer: second, capability: secret, epoch: secondEpoch)
            try repository.apply(producer: first, capability: secret, epoch: firstEpoch, revision: 1, destinations: [destination])
        }
        let reopened = try OwnedAttentionRepository(databaseURL: url, create: false)
        let snapshot = try reopened.projectionSnapshot()
        #expect(snapshot.states.count == 2)
        #expect(snapshot.states[first]?.destinations == [destination])
        #expect(snapshot.states[second]?.destinations == [])
    }

    @Test("Registers and their directory reject extended ACLs")
    func rejectsExtendedACLs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        do { _ = try OwnedAttentionRepository(databaseURL: url, create: true) }
        func addACL(_ path: String) throws {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["+a", "everyone allow read", path]
            try command.run()
            command.waitUntilExit()
            #expect(command.terminationStatus == 0)
        }
        try addACL(url.path)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: false) }
        try FileManager.default.removeItem(at: url)
        try addACL(directory.path)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: true) }
    }

    @Test("A writable register directory is rejected before creating or opening a database")
    func rejectsWritableDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        do { _ = try OwnedAttentionRepository(databaseURL: url, create: true) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: false) }
        let other = directory.appendingPathComponent("other.sqlite3")
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: other, create: true) }
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test("A new register is private even with a permissive process umask")
    func privatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        _ = try OwnedAttentionRepository(databaseURL: url, create: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
    }

    @Test("Reopening rejects a register whose permissions were widened")
    func rejectsInsecureExistingRegister() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        do { _ = try OwnedAttentionRepository(databaseURL: url, create: true) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: false) }
    }

    @Test("Provisioning does not reuse or delete orphan SQLite sidecars")
    func rejectsOrphanSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["-wal", "-shm", "-journal"] {
            let url = directory.appendingPathComponent("state-\(UUID()).sqlite3")
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            try Data("old".utf8).write(to: sidecar)
            #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: true) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(try Data(contentsOf: sidecar) == Data("old".utf8))
        }
    }

    @Test("Concurrent connections elect one successor and preserve attention")
    func concurrentTakeover() throws {
        final class Outcomes: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Result<OwnedAttentionState, any Error>] = []
            func append(_ value: Result<OwnedAttentionState, any Error>) {
                lock.lock(); defer { lock.unlock() }; values.append(value)
            }
            func snapshot() -> [Result<OwnedAttentionState, any Error>] {
                lock.lock(); defer { lock.unlock() }; return values
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID(), capability = secret
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "")
        let first = try OwnedAttentionRepository(databaseURL: url, create: true)
        try first.register(producer: producer, capability: capability, epoch: epoch)
        try first.apply(producer: producer, capability: capability, epoch: epoch, revision: 3, destinations: [destination])
        let second = try OwnedAttentionRepository(databaseURL: url, create: false)
        let group = DispatchGroup(), start = DispatchSemaphore(value: 0), outcomes = Outcomes()
        for repo in [first, second] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                start.wait()
                outcomes.append(Result { try repo.resume(producer: producer, capability: capability, expectedEpoch: epoch, requestID: UUID()) })
            }
        }
        defer { group.wait() }
        start.signal(); start.signal()
        #expect(group.wait(timeout: .now() + 15) == .success)
        let results = outcomes.snapshot()
        let winners = results.compactMap { try? $0.get() }
        #expect(results.count == 2)
        #expect(winners.count == 1)
        #expect(results.contains { result in if case .failure(let error) = result { return error as? OwnedAttentionStateError == .wrongEpoch }; return false })
        let winner = try #require(winners.first)
        #expect(winner.destinations == [destination])
        #expect(try first.read(producer: producer, capability: capability) == winner)
        #expect(throws: OwnedAttentionStateError.wrongEpoch) {
            try second.apply(producer: producer, capability: capability, epoch: epoch, revision: 4, destinations: [])
        }
    }
    @Test("A resumed writer fences its predecessor without exposing state to a wrong capability")
    func resumesAndAuthenticates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID(), secret = Data(repeating: 1, count: 32)
        let repo = try OwnedAttentionRepository(databaseURL: url, create: true)
        try repo.register(producer: producer, capability: secret, epoch: epoch)
        try repo.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [])
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) {
            try repo.read(producer: producer, capability: Data(repeating: 2, count: 32))
        }
        let request = UUID()
        let resumed = try repo.resume(producer: producer, capability: secret, expectedEpoch: epoch, requestID: request)
        #expect(resumed.revision == 0)
        #expect(resumed.epoch != epoch)
        #expect(try repo.resume(producer: producer, capability: secret, expectedEpoch: epoch, requestID: request) == resumed)
        #expect(throws: OwnedAttentionStateError.wrongEpoch) {
            try repo.apply(producer: producer, capability: secret, epoch: epoch, revision: 2, destinations: [])
        }
        try repo.apply(producer: producer, capability: secret, epoch: resumed.epoch, revision: 2, destinations: [])
        let successor = try repo.resume(producer: producer, capability: secret, expectedEpoch: resumed.epoch, requestID: UUID())
        #expect(throws: OwnedAttentionStateError.wrongEpoch) {
            try repo.resume(producer: producer, capability: secret, expectedEpoch: epoch, requestID: request)
        }
        #expect(try repo.read(producer: producer, capability: secret)?.epoch == successor.epoch)
    }

    @Test("A committed state survives reopening and rejects stale writers")
    func persistsAndFences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        let destination = OwnedAttentionDestination(workspaceID: UUID(), surfaceID: UUID(), title: "waiting", body: "")
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            try repository.register(producer: producer, capability: secret, epoch: epoch)
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [destination])
        }
        let reopened = try OwnedAttentionRepository(databaseURL: url, create: false)
        #expect(try reopened.read(producer: producer, capability: secret)?.destinations == [destination])
        try reopened.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [destination])
        #expect(throws: OwnedAttentionStateError.staleRevision) {
            try reopened.apply(producer: producer, capability: secret, epoch: epoch, revision: 0, destinations: [])
        }
        #expect(throws: OwnedAttentionStateError.wrongEpoch) {
            try reopened.apply(producer: producer, capability: secret, epoch: UUID(), revision: 2, destinations: [])
        }
        #expect(try reopened.read(producer: producer, capability: secret)?.revision == 1)
    }

    @Test("Opening a missing existing register fails closed")
    func missingRegister() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missing.sqlite3")
        #expect(throws: (any Error).self) {
            try OwnedAttentionRepository(databaseURL: url, create: false)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Interrupted provisioning does not publish a partial register")
    func interruptedProvisioning() throws {
        enum Failure: Error { case injected }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        #expect(throws: Failure.injected) {
            try OwnedAttentionRepository(databaseURL: url, create: true, beforePublish: { throw Failure.injected })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try OwnedAttentionRepository(databaseURL: url, create: true)
    }

    @Test("A register with extra mutation triggers is rejected")
    func rejectsUnexpectedSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        do { _ = try OwnedAttentionRepository(databaseURL: url, create: true) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TRIGGER sqliteXwipe AFTER UPDATE ON owned_attention BEGIN DELETE FROM owned_attention; END", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: false) }
    }

    @Test("Corrupt stored state is reported as a storage failure")
    func rejectsCorruptPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        let producer = UUID(), epoch = UUID()
        do { let repo = try OwnedAttentionRepository(databaseURL: url, create: true); try repo.register(producer: producer, capability: secret, epoch: epoch) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "UPDATE owned_attention SET payload = payload || char(0) || 'invalid'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let repository = try OwnedAttentionRepository(databaseURL: url, create: false)
        let wrong = Data(repeating: 7, count: 32)
        #expect(throws: OwnedAttentionRepositoryError.producerExists) { try repository.register(producer: producer, capability: wrong, epoch: epoch) }
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) { try repository.read(producer: producer, capability: wrong) }
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) { try repository.apply(producer: producer, capability: wrong, epoch: epoch, revision: 1, destinations: []) }
        #expect(throws: OwnedAttentionRepositoryError.unauthorized) { try repository.resume(producer: producer, capability: wrong, expectedEpoch: epoch, requestID: UUID()) }
        do {
            try repository.apply(producer: producer, capability: secret, epoch: epoch, revision: 1, destinations: [])
            Issue.record("corrupt payload accepted")
        } catch OwnedAttentionRepositoryError.storage {
            // Expected storage failure, not an invalid-request error.
        }
    }

    @Test("A new writer epoch recovers from revision exhaustion")
    func resumeAfterRevisionExhaustion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try OwnedAttentionRepository(databaseURL: directory.appendingPathComponent("state.sqlite3"), create: true)
        let producer = UUID(), epoch = UUID()
        try repo.register(producer: producer, capability: secret, epoch: epoch)
        try repo.apply(producer: producer, capability: secret, epoch: epoch, revision: UInt64.max, destinations: [])
        let next = try repo.resume(producer: producer, capability: secret, expectedEpoch: epoch, requestID: UUID())
        #expect(next.revision == 0)
        try repo.apply(producer: producer, capability: secret, epoch: next.epoch, revision: 1, destinations: [])
        #expect(throws: OwnedAttentionStateError.wrongEpoch) {
            try repo.apply(producer: producer, capability: secret, epoch: epoch, revision: UInt64.max, destinations: [])
        }
    }

    @Test("An inconsistent producer index is rejected on reopen")
    func rejectsCorruptIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-attention-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite3")
        do {
            let repository = try OwnedAttentionRepository(databaseURL: url, create: true)
            try repository.register(producer: UUID(), capability: secret, epoch: UUID())
        }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "SELECT rootpage FROM sqlite_master WHERE type='index'", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let root = Int(sqlite3_column_int(statement, 0))
        sqlite3_finalize(statement)
        sqlite3_close(database)
        var bytes = try Data(contentsOf: url)
        let pageSize = Int(bytes[16]) * 256 + Int(bytes[17])
        let start = (root - 1) * pageSize
        bytes.replaceSubrange((start + 1)..<(start + 8), with: [0, 0, 0, 0, UInt8(pageSize >> 8), UInt8(pageSize & 255), 0])
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try OwnedAttentionRepository(databaseURL: url, create: false) }
    }

}
