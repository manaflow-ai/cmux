public import Foundation

/// Typed decoder for the `terminal.input` RPC result.
///
/// The only field the iOS client reads is `terminal_seq`: the Mac's authoritative
/// end sequence for the surface after applying the input. The client compares it
/// against its locally delivered end sequence to decide whether it is behind and
/// must replay or wait.
public struct MobileTerminalInputResponse: Decodable, Sendable {
    /// The Mac's authoritative terminal end sequence after applying the input,
    /// if reported.
    public let terminalSeq: UInt64?

    private enum CodingKeys: String, CodingKey {
        case terminalSeq = "terminal_seq"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalSeq = try container.decodeIfPresent(UInt64.self, forKey: .terminalSeq)
    }

    /// Decode a terminal-input response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileTerminalInputResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
