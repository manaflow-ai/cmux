import Foundation
import os

/// A process-local ``CloudSecretVaultStorage`` for tests and previews.
public final class InMemoryCloudSecretVaultStorage: CloudSecretVaultStorage, @unchecked Sendable {
    // @unchecked: the only stored state is behind `lock`, an OSAllocatedUnfairLock whose
    // critical sections are short synchronous copies.
    private let lock: OSAllocatedUnfairLock<Data?>

    public init(data: Data? = nil) {
        lock = OSAllocatedUnfairLock(initialState: data)
    }

    public func load() throws -> Data? {
        lock.withLock { $0 }
    }

    public func save(_ data: Data) throws {
        lock.withLock { $0 = data }
    }

    public func delete() throws {
        lock.withLock { $0 = nil }
    }
}
