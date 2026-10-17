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

/// Typed decoder for the `mobile.terminal.paste` RPC result.
///
/// A paste can be accepted while its submit key fails, so callers must inspect
/// `submitted` instead of treating a successful RPC response as a committed
/// prompt.
public struct MobileTerminalPasteResponse: Decodable, Sendable {
    public let submitted: Bool
    /// Whether the prompt text reached the terminal input. Older hosts omit
    /// this field; callers infer it from the request shape when needed.
    public let textAccepted: Bool?
    /// A short host-side reason when the paste was accepted but its submit key
    /// was not. The text is intentionally optional because older hosts only
    /// reported the boolean.
    public let submitError: String?

    private enum CodingKeys: String, CodingKey {
        case submitted
        case textAccepted = "text_accepted"
        case submitError = "submit_error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        submitted = try container.decodeIfPresent(Bool.self, forKey: .submitted) ?? false
        textAccepted = try container.decodeIfPresent(Bool.self, forKey: .textAccepted)
        submitError = try container.decodeIfPresent(String.self, forKey: .submitError)
    }

    public static func decode(_ data: Data) throws -> MobileTerminalPasteResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
