public import CmuxTerminalBackend
public import CmuxTerminalBackendService
public import Foundation

/// One readiness-fenced canonical connection used by the lightweight Swift host.
public struct BackendOnlyHostConnection: Sendable {
    /// The canonical backend session.
    public let session: BackendCanonicalSession
    /// The readiness receipt that fenced this connection.
    public let readiness: BackendServiceReadiness
    /// The topology snapshot captured at connection time.
    public let initialSnapshot: TopologySnapshot
    /// The stable frontend client identifier.
    public let stableClientID: UUID
    /// The identifier for this frontend process instance.
    public let processInstanceID: UUID

    /// Creates a readiness-fenced host connection.
    public init(
        session: BackendCanonicalSession,
        readiness: BackendServiceReadiness,
        initialSnapshot: TopologySnapshot,
        stableClientID: UUID,
        processInstanceID: UUID
    ) {
        self.session = session
        self.readiness = readiness
        self.initialSnapshot = initialSnapshot
        self.stableClientID = stableClientID
        self.processInstanceID = processInstanceID
    }
}
