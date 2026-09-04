public import Foundation
import Synchronization

/// A process-local identity store for tests and previews.
public actor InMemoryCloudDeviceIdentityStore: CloudDeviceIdentityStoring {
    private struct State: Sendable {
        var identity: CloudDeviceIdentity?
        var unavailable: Bool
    }

    private var state: State

    /// Creates a store.
    /// - Parameters:
    ///   - identity: An initial stored identity, or nil for a fresh install.
    ///   - unavailable: When true, reads report `.unavailable` (a locked store).
    public init(identity: CloudDeviceIdentity? = nil, unavailable: Bool = false) {
        state = State(identity: identity, unavailable: unavailable)
    }

    public func read() -> CloudDeviceIdentityReadResult {
        if state.unavailable { return .unavailable }
        if let identity = state.identity { return .found(identity) }
        return .absent
    }

    public func write(_ identity: CloudDeviceIdentity) throws {
        state.identity = identity
    }

    /// The identity currently held, for assertions.
    public var stored: CloudDeviceIdentity? { state.identity }
}
