internal import Foundation

/// Validates backend identity and protocol compatibility before state exchange.
public struct BackendHandshakePolicy: Equatable, Sendable {
    /// Capabilities required before opting a connection into protocol v9 mutation authority.
    public static let terminalControlV9Capabilities: Set<String> = [
        "terminal-control-lease-v1",
        "terminal-split-leases-v1",
        "terminal-lease-transfer-v1",
        "terminal-input-delegation-v1",
        "terminal-input-groups-v1",
        "terminal-global-input-order-v1",
        "terminal-input-idempotency-v1",
        "terminal-input-receipt-ack-v1",
        "terminal-ordered-input-v1",
        "terminal-activity-v1",
    ]

    /// The protocol version and capabilities required for terminal mutation authority.
    public static let terminalAuthorityV1 = BackendHandshakePolicy(
        supportedRange: 8 ... 9,
        minimumReadWriteProtocol: 9,
        requiredCapabilities: Set([
            "canonical-topology-snapshot-v1",
            "canonical-topology-mutations-v1",
            "durable-session-identity-v1",
            "ensure-terminal-v1",
            "presentation-registry-v1",
            "projection-state-reconnect-v1",
            "renderer-semantic-scene-v1",
            "renderer-worker-supervision-v1",
            "reparent-terminal-v1",
            "stable-entity-uuid-v1",
            "terminal-accessibility-v1",
            "terminal-interaction-v1",
            "terminal-link-hit-v1",
            "topology-resume-v1",
        ]).union(terminalControlV9Capabilities)
    )

    /// The expected backend application identifier.
    public let application: String

    /// The inclusive range of protocol versions supported by the client.
    public let supportedRange: ClosedRange<UInt32>

    /// The minimum negotiated protocol version that may mutate backend state.
    public let minimumReadWriteProtocol: UInt32

    /// The capabilities the backend must advertise before mutation is enabled.
    public let requiredCapabilities: Set<String>

    /// Creates a backend handshake policy.
    ///
    /// - Parameters:
    ///   - application: The expected backend application identifier.
    ///   - supportedRange: The protocol versions supported by the client.
    ///   - minimumReadWriteProtocol: The oldest protocol that may mutate state.
    ///     Defaults to the lower bound for generic policies.
    ///   - requiredCapabilities: The capabilities required for mutation authority.
    public init(
        application: String = "cmux-tui",
        supportedRange: ClosedRange<UInt32> = 8 ... 9,
        minimumReadWriteProtocol: UInt32? = nil,
        requiredCapabilities: Set<String>
    ) {
        self.application = application
        self.supportedRange = supportedRange
        self.minimumReadWriteProtocol = minimumReadWriteProtocol ?? supportedRange.lowerBound
        self.requiredCapabilities = requiredCapabilities
    }

    /// Validates a backend identity response against this policy.
    ///
    /// - Parameter response: The backend identity response to validate.
    /// - Returns: Explicit read-write authority or a connected read-only diagnostic.
    /// - Throws: ``BackendProtocolError/unexpectedApplication(_:)``,
    ///   or ``BackendProtocolError/malformedMessage`` when identity metadata is invalid.
    @discardableResult
    public func validate(_ response: BackendIdentifyResponse) throws -> BackendCompatibilityResult {
        guard response.app == application else {
            throw BackendProtocolError.unexpectedApplication(response.app)
        }
        guard response.protocolMinimum <= response.protocolMaximum else {
            throw BackendProtocolError.malformedMessage
        }
        let serverRange = response.protocolMinimum ... response.protocolMaximum
        let lower = max(supportedRange.lowerBound, serverRange.lowerBound)
        let upper = min(supportedRange.upperBound, serverRange.upperBound)
        let negotiatedProtocol = lower <= upper ? upper : nil
        let missing = requiredCapabilities.subtracting(response.capabilities)
        var reasons: Set<BackendReadOnlyReason> = []
        if negotiatedProtocol == nil {
            reasons.insert(.incompatibleProtocol)
        } else if let negotiatedProtocol, negotiatedProtocol < minimumReadWriteProtocol {
            reasons.insert(.protocolTooOld)
        }
        if !missing.isEmpty {
            reasons.insert(.missingCapabilities)
        }
        if let negotiatedProtocol, reasons.isEmpty {
            return .readWrite(BackendReadWriteCompatibility(
                clientProtocolRange: supportedRange,
                serverProtocolRange: serverRange,
                negotiatedProtocol: negotiatedProtocol,
                requiredCapabilities: requiredCapabilities
            ))
        }
        return .readOnly(BackendReadOnlyCompatibility(
            clientProtocolRange: supportedRange,
            serverProtocolRange: serverRange,
            negotiatedProtocol: negotiatedProtocol,
            minimumReadWriteProtocol: minimumReadWriteProtocol,
            requiredCapabilities: requiredCapabilities,
            missingCapabilities: missing,
            reasons: reasons
        ))
    }
}
