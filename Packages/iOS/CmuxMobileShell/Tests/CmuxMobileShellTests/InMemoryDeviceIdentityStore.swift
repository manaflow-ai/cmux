import Foundation
@testable import CmuxMobileShell

/// In-memory device-identity store double for tests. Lives in the test target so
/// no test-only type ships in the `CmuxMobileShell` production Sources.
final class InMemoryDeviceIdentityStore: DeviceIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    /// Simulates a store that cannot be read (e.g. a locked Keychain): `read()`
    /// returns `.unavailable` regardless of the seed, exercising the caller's
    /// fail-closed path.
    private let isUnavailable: Bool
    /// Simulates a store that can be read but never persists a write (e.g. a
    /// Keychain that rejects `SecItemAdd`), exercising the caller's
    /// do-not-advertise-as-durable path.
    private let writeAlwaysFails: Bool

    init(seed: String? = nil, unavailable: Bool = false, writeAlwaysFails: Bool = false) {
        value = seed
        isUnavailable = unavailable
        self.writeAlwaysFails = writeAlwaysFails
    }

    func read() -> DeviceIdentityReadResult {
        if isUnavailable { return .unavailable }
        return lock.withLock {
            guard let value, !value.isEmpty else { return .absent }
            return .found(value)
        }
    }

    func createOrAdopt(_ desired: String) -> String? {
        if isUnavailable || writeAlwaysFails { return nil }
        return lock.withLock {
            // Adopt an already-persisted winner instead of overwriting it, so
            // racing callers converge on one id.
            if let value, !value.isEmpty { return value }
            value = desired
            return desired
        }
    }
}
