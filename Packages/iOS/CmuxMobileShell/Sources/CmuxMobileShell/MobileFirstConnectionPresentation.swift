public import Foundation

/// Whether the account registry produced an authoritative first-connection result.
public enum MobileFirstConnectionRegistryState: Equatable, Sendable {
    case loading
    case loaded(hasAccountSession: Bool)
    case authRejected
    case unavailable
}

/// Result of refreshing the account-scoped device registry.
public enum MobileRegistryLoadResult: Equatable, Sendable {
    case loaded
    case authRejected
    case unavailable
}

/// Keeps account-discovered sessions fresh before their two-minute registry lease expires.
public struct MobileFirstConnectionRegistryRefreshPolicy: Equatable, Sendable {
    public let refreshInterval: TimeInterval

    /// The Mac renews every 60 seconds. Forty seconds leaves margin for the
    /// caller's 10-second polling granularity and scheduling jitter.
    public init(refreshInterval: TimeInterval = 40) {
        self.refreshInterval = refreshInterval
    }

    public func shouldRefresh(lastRefreshAt: Date?, now: Date = Date()) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= refreshInterval
    }
}

/// Owns why the shared Add Computer sheet is visible so discovery can dismiss
/// only the sheet it presented automatically.
public enum MobileAddDevicePresentationOrigin: Equatable, Sendable {
    case userInitiated
    case automaticFirstConnection
    case attachTicketApproval
}

public struct MobileAddDevicePresentationState: Equatable, Sendable {
    public private(set) var origin: MobileAddDevicePresentationOrigin?

    public init(origin: MobileAddDevicePresentationOrigin? = nil) {
        self.origin = origin
    }

    public var isPresented: Bool { origin != nil }

    public mutating func present(origin: MobileAddDevicePresentationOrigin) {
        self.origin = origin
    }

    public mutating func presentAutomaticallyIfUnowned() {
        guard origin == nil else { return }
        origin = .automaticFirstConnection
    }

    public mutating func dismiss() {
        origin = nil
    }

    public mutating func dismissAutomaticForAvailableSession() {
        guard origin == .automaticFirstConnection else { return }
        origin = nil
    }
}

/// Mutually exclusive connection activity on the first-connection screen.
public struct MobileFirstConnectionAttemptState: Equatable, Sendable {
    public let connectingSavedComputerID: String?
    public let pendingHandoffID: String?

    public init(
        connectingSavedComputerID: String?,
        pendingHandoffID: String?
    ) {
        self.connectingSavedComputerID = connectingSavedComputerID
        self.pendingHandoffID = pendingHandoffID
    }

    public var canStartConnection: Bool {
        connectingSavedComputerID == nil && pendingHandoffID == nil
    }
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
