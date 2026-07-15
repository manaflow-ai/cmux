/// Whether the account registry produced an authoritative first-connection result.
public enum MobileFirstConnectionRegistryState: Equatable, Sendable {
    case loading
    case loaded(hasAccountSession: Bool)
    case unavailable
}

/// Result of refreshing the account-scoped device registry.
public enum MobileRegistryLoadResult: Equatable, Sendable {
    case loaded
    case unavailable
}

/// Connection choices available to a signed-in installation before its first attach.
public struct MobileFirstConnectionState: Equatable, Sendable {
    public let hasSavedComputer: Bool
    public let registryState: MobileFirstConnectionRegistryState

    public init(
        hasSavedComputer: Bool,
        registryState: MobileFirstConnectionRegistryState
    ) {
        self.hasSavedComputer = hasSavedComputer
        self.registryState = registryState
    }

    public var shouldPresentManualPairing: Bool {
        guard !hasSavedComputer,
              case .loaded(hasAccountSession: false) = registryState else {
            return false
        }
        return true
    }
}
