public import Foundation

/// Private connection details for one durable remote tmux producer identity.
///
/// This value is retained only in daemon memory. It must never appear in
/// canonical topology, durable state, diagnostics, or errors.
public struct BackendRemoteTmuxProducerSource: Codable, Equatable, Sendable,
    CustomDebugStringConvertible
{
    public let destination: String
    public let port: UInt16?
    public let identityFile: String?
    public let sessionName: String

    public init(
        destination: String,
        port: UInt16? = nil,
        identityFile: String? = nil,
        sessionName: String
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sessionName = sessionName
    }

    public var debugDescription: String {
        "BackendRemoteTmuxProducerSource(destination: <redacted>, port: \(port.map { _ in "<present>" } ?? "nil"), identityFile: \(identityFile == nil ? "nil" : "<present>"), sessionName: <redacted>)"
    }

    internal var jsonValue: BackendJSONValue {
        var fields: [String: BackendJSONValue] = [
            "destination": .string(destination),
            "session_name": .string(sessionName),
        ]
        if let port {
            fields["port"] = .unsignedInteger(UInt64(port))
        }
        if let identityFile {
            fields["identity_file"] = .string(identityFile)
        }
        return .object(fields)
    }

    private enum CodingKeys: String, CodingKey {
        case destination
        case port
        case identityFile = "identity_file"
        case sessionName = "session_name"
    }
}

/// Connection-owned claim over one remote tmux producer's private source.
public struct BackendRemoteTmuxProducerSourceClaimReceipt: Codable, Equatable, Sendable,
    CustomDebugStringConvertible
{
    public let requestID: UUID
    public let daemonInstanceID: DaemonInstanceID
    public let sessionID: SessionID
    public let producerID: UUID
    public let ownerGeneration: UInt64
    public let source: BackendRemoteTmuxProducerSource?
    public let replayed: Bool

    public var authority: BackendAuthority {
        BackendAuthority(daemonInstanceID: daemonInstanceID, sessionID: sessionID)
    }

    public init(
        requestID: UUID,
        daemonInstanceID: DaemonInstanceID,
        sessionID: SessionID,
        producerID: UUID,
        ownerGeneration: UInt64,
        source: BackendRemoteTmuxProducerSource?,
        replayed: Bool
    ) {
        self.requestID = requestID
        self.daemonInstanceID = daemonInstanceID
        self.sessionID = sessionID
        self.producerID = producerID
        self.ownerGeneration = ownerGeneration
        self.source = source
        self.replayed = replayed
    }

    public var debugDescription: String {
        "BackendRemoteTmuxProducerSourceClaimReceipt(requestID: \(requestID), producerID: \(producerID), ownerGeneration: \(ownerGeneration), sourcePresent: \(source != nil), replayed: \(replayed))"
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case producerID = "producer_id"
        case ownerGeneration = "owner_generation"
        case source
        case replayed
    }
}

/// Acknowledges a generation-fenced private producer-source update.
public struct BackendRemoteTmuxProducerSourceUpdateReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let daemonInstanceID: DaemonInstanceID
    public let sessionID: SessionID
    public let producerID: UUID
    public let ownerGeneration: UInt64
    public let replayed: Bool

    public var authority: BackendAuthority {
        BackendAuthority(daemonInstanceID: daemonInstanceID, sessionID: sessionID)
    }

    public init(
        requestID: UUID,
        daemonInstanceID: DaemonInstanceID,
        sessionID: SessionID,
        producerID: UUID,
        ownerGeneration: UInt64,
        replayed: Bool
    ) {
        self.requestID = requestID
        self.daemonInstanceID = daemonInstanceID
        self.sessionID = sessionID
        self.producerID = producerID
        self.ownerGeneration = ownerGeneration
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case producerID = "producer_id"
        case ownerGeneration = "owner_generation"
        case replayed
    }
}
