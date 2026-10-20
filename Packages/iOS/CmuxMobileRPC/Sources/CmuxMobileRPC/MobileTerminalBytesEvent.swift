public import Foundation

/// Typed decoder for a `terminal.bytes` push-event payload.
///
/// Raw PTY bytes from the Mac surface's libghostty pty-tee, the compatibility
/// fallback when the host does not advertise the render-grid capability. The
/// base64 `data_b64` is decoded into ``bytes``; `seq` (when present) is the start
/// sequence the client uses to detect gaps and overlaps against its delivered
/// end sequence.
public struct MobileTerminalBytesEvent: Decodable, Sendable {
    /// The surface the bytes belong to.
    public let surfaceID: String
    /// The decoded raw PTY bytes.
    public let bytes: Data
    /// The start sequence of this byte run, if reported.
    public let sequence: UInt64?

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case dataBase64 = "data_b64"
        case sequence = "seq"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceID = try container.decode(String.self, forKey: .surfaceID)
        let base64 = try container.decode(String.self, forKey: .dataBase64)
        guard let decoded = Data(base64Encoded: base64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .dataBase64,
                in: container,
                debugDescription: "data_b64 is not valid base64"
            )
        }
        bytes = decoded
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
    }

    /// Decode a `terminal.bytes` event from a raw JSON payload.
    /// - Parameter data: The event payload JSON.
    /// - Returns: The decoded event, or `nil` when the payload is malformed
    ///   (missing `surface_id`/`data_b64` or invalid base64), mirroring the
    ///   legacy guard that silently dropped such frames.
    public static func decode(_ data: Data) -> MobileTerminalBytesEvent? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}
