import CmuxPeerTransport
import Foundation

/// The JSON descriptor carried in a raw stream's `raw.open` handshake: which
/// legacy lane the bytes that follow belong to. Replaces the legacy CMUXIRH1
/// binary stream header; everything after the handshake is the legacy in-lane
/// payload, verbatim.
public struct PtxLaneDescriptor: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case control
        case serverEvents = "server_events"
        case terminal
        case artifact
        case simulatorStream = "simulator_stream"
    }

    public var lane: Kind
    public var resourceID: String?
    public var cursor: UInt64?
    public var offset: UInt64?

    public init(
        lane: Kind, resourceID: String? = nil, cursor: UInt64? = nil, offset: UInt64? = nil
    ) {
        self.lane = lane
        self.resourceID = resourceID
        self.cursor = cursor
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey {
        case lane
        case resourceID = "resource_id"
        case cursor
        case offset
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public init(encoded: String) throws {
        self = try JSONDecoder().decode(PtxLaneDescriptor.self, from: Data(encoded.utf8))
    }
}
