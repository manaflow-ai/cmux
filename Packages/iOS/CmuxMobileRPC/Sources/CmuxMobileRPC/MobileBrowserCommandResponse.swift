import Foundation

/// Typed acknowledgement returned by browser lifecycle, input, and chrome commands.
public struct MobileBrowserCommandResponse: Decodable, Sendable {
    /// Whether a generic action succeeded.
    public let ok: Bool?
    /// Whether a stream was stopped.
    public let stopped: Bool?
    /// Whether a frame was acknowledged.
    public let acknowledged: Bool?
    /// The affected panel identifier.
    public let panelID: String?
    /// The affected frame sequence.
    public let sequence: UInt64?

    private enum CodingKeys: String, CodingKey {
        case ok, stopped
        case acknowledged = "acked"
        case panelID = "panel_id"
        case sequence = "seq"
    }

    /// Decodes a browser command result.
    static func decode(_ data: Data) throws -> MobileBrowserCommandResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
