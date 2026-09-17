/// Why a line failed to decode as a v2 request envelope.
///
/// Each case maps 1:1 onto a legacy dispatcher error response; see
/// `ControlResponseEncoder.response(for:)` for the exact wire strings.
public enum ControlRequestParseError: Error, Sendable, Equatable {
    /// The line could not be encoded as UTF-8 bytes.
    case invalidUTF8
    /// The bytes were not valid JSON.
    case invalidJSON
    /// The JSON was valid but the top level was not an object.
    case notAnObject
    /// The object had no non-empty `method`. Carries the parsed `id` so the
    /// error response can still echo it.
    case missingMethod(id: JSONValue?)
}
