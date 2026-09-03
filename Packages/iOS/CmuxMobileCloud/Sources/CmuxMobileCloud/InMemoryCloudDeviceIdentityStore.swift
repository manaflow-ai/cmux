public import Foundation
import os

/// A process-local identity store for tests and previews.
public final class InMemoryCloudDeviceIdentityStore: CloudDeviceIdentityStoring, Sendable {
    private struct State: Sendable {
        var identity: CloudDeviceIdentity?
        var unavailable: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Creates a store.
    /// - Parameters:
    ///   - identity: An initial stored identity, or nil for a fresh install.
    ///   - unavailable: When true, reads report `.unavailable` (a locked store).
    public init(identity: CloudDeviceIdentity? = nil, unavailable: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(identity: identity, unavailable: unavailable))
    }

    public func read() -> CloudDeviceIdentityReadResult {
        state.withLock { state in
            if state.unavailable { return .unavailable }
            if let identity = state.identity { return .found(identity) }
            return .absent
        }
    }

    public func write(_ identity: CloudDeviceIdentity) throws {
        state.withLock { $0.identity = identity }
    }

    /// The identity currently held, for assertions.
    public var stored: CloudDeviceIdentity? {
        state.withLock { $0.identity }
    }
}
