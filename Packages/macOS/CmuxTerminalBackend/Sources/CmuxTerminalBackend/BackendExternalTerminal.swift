public import Foundation

/// Ownership fence returned when one registered frontend claims a parser-only terminal.
public struct BackendExternalTerminalClaimReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let ownerGeneration: UInt64
    public let requiredOutputGeneration: UInt64
    public let replayed: Bool

    public init(
        requestID: UUID,
        ownerGeneration: UInt64,
        requiredOutputGeneration: UInt64,
        replayed: Bool
    ) {
        self.requestID = requestID
        self.ownerGeneration = ownerGeneration
        self.requiredOutputGeneration = requiredOutputGeneration
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ownerGeneration = "owner_generation"
        case requiredOutputGeneration = "required_output_generation"
        case replayed
    }
}

/// Ordered parser result plus bytes that must be forwarded to the external PTY owner.
public struct BackendExternalTerminalOutputReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let ownerGeneration: UInt64
    public let outputGeneration: UInt64
    public let acceptedSequence: UInt64
    public let nextSequence: UInt64
    public let noReflow: Bool
    public let egress: Data
    public let replayed: Bool

    public init(
        requestID: UUID,
        ownerGeneration: UInt64,
        outputGeneration: UInt64,
        acceptedSequence: UInt64,
        nextSequence: UInt64,
        noReflow: Bool,
        egress: Data,
        replayed: Bool
    ) {
        self.requestID = requestID
        self.ownerGeneration = ownerGeneration
        self.outputGeneration = outputGeneration
        self.acceptedSequence = acceptedSequence
        self.nextSequence = nextSequence
        self.noReflow = noReflow
        self.egress = egress
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ownerGeneration = "owner_generation"
        case outputGeneration = "output_generation"
        case acceptedSequence = "accepted_sequence"
        case nextSequence = "next_sequence"
        case noReflow = "no_reflow"
        case egress
        case replayed
    }
}

struct BackendExternalTerminalEgressResponse: Decodable {
    let egress: Data
}
