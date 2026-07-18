internal import Foundation

/// Validates backend identity and protocol compatibility before state exchange.
public struct BackendHandshakePolicy: Equatable, Sendable {
    /// The protocol version and capabilities required for terminal authority.
    public static let terminalAuthorityV1 = BackendHandshakePolicy(
        requiredCapabilities: [
            "canonical-topology-snapshot-v1",
            "durable-session-identity-v1",
            "presentation-registry-v1",
            "stable-entity-uuid-v1",
            "topology-resume-v1",
        ]
    )

    /// The expected backend application identifier.
    public let application: String

    /// The inclusive range of protocol versions supported by the client.
    public let supportedRange: ClosedRange<UInt32>

    /// The capabilities the backend must advertise.
    public let requiredCapabilities: Set<String>

    /// Creates a backend handshake policy.
    ///
    /// - Parameters:
    ///   - application: The expected backend application identifier.
    ///   - supportedRange: The protocol versions supported by the client.
    ///   - requiredCapabilities: The capabilities the backend must advertise.
    public init(
        application: String = "cmux-tui",
        supportedRange: ClosedRange<UInt32> = 8 ... 8,
        requiredCapabilities: Set<String>
    ) {
        self.application = application
        self.supportedRange = supportedRange
        self.requiredCapabilities = requiredCapabilities
    }

    /// Validates a backend identity response against this policy.
    ///
    /// - Parameter response: The backend identity response to validate.
    /// - Returns: The highest mutually supported protocol version.
    /// - Throws: ``BackendProtocolError/unexpectedApplication(_:)``,
    ///   ``BackendProtocolError/incompatibleProtocol(client:server:)``, or
    ///   ``BackendProtocolError/missingCapabilities(_:)`` when validation fails.
    @discardableResult
    public func validate(_ response: BackendIdentifyResponse) throws -> UInt32 {
        guard response.app == application else {
            throw BackendProtocolError.unexpectedApplication(response.app)
        }
        guard response.protocolMinimum <= response.protocolMaximum else {
            throw BackendProtocolError.malformedMessage
        }
        let serverRange = response.protocolMinimum ... response.protocolMaximum
        let lower = max(supportedRange.lowerBound, serverRange.lowerBound)
        let upper = min(supportedRange.upperBound, serverRange.upperBound)
        guard lower <= upper else {
            throw BackendProtocolError.incompatibleProtocol(
                client: supportedRange,
                server: serverRange
            )
        }
        let missing = requiredCapabilities.subtracting(response.capabilities)
        guard missing.isEmpty else {
            throw BackendProtocolError.missingCapabilities(missing)
        }
        return upper
    }
}
