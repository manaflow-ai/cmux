import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohAppInstanceRepositoryTests {
    @Test
    func identifierIsStableOnlyWithinTheSameAccountAndTag() async throws {
        let store = AppInstanceMemoryStore()
        let values = UUIDSequence([
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174001")!,
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174002")!,
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174003")!,
        ])
        let repository = CmxIrohAppInstanceRepository(
            store: store,
            makeUUID: { values.next() }
        )

        let first = try await repository.appInstanceID(accountID: "account-a", tag: "default")
        let repeated = try await repository.appInstanceID(accountID: "account-a", tag: "default")
        let switchedAccount = try await repository.appInstanceID(
            accountID: "account-b",
            tag: "default"
        )
        let switchedTag = try await repository.appInstanceID(accountID: "account-b", tag: "dev")

        #expect(first == repeated)
        #expect(first != switchedAccount)
        #expect(switchedAccount != switchedTag)
        #expect(first == first.lowercased())
    }

    @Test
    func deactivationNeverReusesThePriorBindingIdentity() async throws {
        let store = AppInstanceMemoryStore()
        let values = UUIDSequence([
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174011")!,
            UUID(uuidString: "123e4567-e89b-42d3-a456-426614174012")!,
        ])
        let repository = CmxIrohAppInstanceRepository(
            store: store,
            makeUUID: { values.next() }
        )
        let first = try await repository.appInstanceID(accountID: "account", tag: "default")

        await repository.deactivate()
        let second = try await repository.appInstanceID(accountID: "account", tag: "default")

        #expect(first != second)
    }
}

private final class AppInstanceMemoryStore: CmxIrohInstallStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) { self.values = values }

    func next() -> UUID {
        lock.withLock { values.removeFirst() }
    }
}
