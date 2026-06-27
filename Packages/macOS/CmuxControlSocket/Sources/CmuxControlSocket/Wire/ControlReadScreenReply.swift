internal import Foundation

/// The decoded reply for the v1 `read_screen` command.
///
/// A pure, `Sendable` value produced by ``decode(_:)`` from the raw
/// `readTerminalTextBase64` reply string. The decode is byte-faithful to the
/// legacy god-file `readScreenText(_:)` reply handling: a reply that does not
/// begin with `"OK "` is passed through verbatim (it is already an error or
/// status line); otherwise the `"OK "` prefix is dropped, the remaining payload
/// is whitespace trimmed, an empty payload decodes to the empty string, a
/// payload that is not valid Base64 yields the verbatim wire error
/// `"ERROR: Failed to decode terminal text"`, and a valid payload is decoded as
/// Base64 then interpreted as UTF-8. The app-side `readScreenText` witness keeps
/// the live `readTerminalTextBase64` read and consumes ``text`` for the wire
/// response.
public struct ControlReadScreenReply: Sendable, Equatable {
    /// The decoded screen text, or the verbatim passthrough/error string when
    /// the reply was not a successful Base64 payload.
    public let text: String

    /// Creates a decoded read-screen reply value.
    ///
    /// - Parameter text: The decoded screen text or verbatim passthrough string.
    public init(text: String) {
        self.text = text
    }

    /// Decodes the raw `readTerminalTextBase64` reply string.
    ///
    /// Byte-faithful to the legacy `readScreenText(_:)` reply handling: a reply
    /// without the `"OK "` prefix is returned verbatim; otherwise the prefix is
    /// dropped, the payload whitespace trimmed, an empty payload yields the empty
    /// string, an undecodable payload yields
    /// `"ERROR: Failed to decode terminal text"`, and a valid Base64 payload is
    /// decoded and interpreted as UTF-8.
    ///
    /// - Parameter response: The raw `readTerminalTextBase64` reply string.
    /// - Returns: The decoded reply.
    public static func decode(_ response: String) -> ControlReadScreenReply {
        guard response.hasPrefix("OK ") else { return ControlReadScreenReply(text: response) }

        let payload = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty {
            return ControlReadScreenReply(text: "")
        }

        guard let data = Data(base64Encoded: payload) else {
            return ControlReadScreenReply(text: "ERROR: Failed to decode terminal text")
        }
        return ControlReadScreenReply(text: String(decoding: data, as: UTF8.self))
    }
}
