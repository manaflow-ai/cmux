/// The outcome of one v2 control command (was `V2CallResult`), fully typed.
///
/// Encoded onto the wire by `ControlResponseEncoder.response(id:_:)` as either
/// `{"id":…,"ok":true,"result":…}` or `{"id":…,"ok":false,"error":…}`.
public enum ControlCallResult: Sendable, Equatable {
    /// The command succeeded with the given result payload.
    case ok(JSONValue)
    /// The command failed.
    ///
    /// - Parameters:
    ///   - code: The machine-readable error code (e.g. `invalid_params`).
    ///   - message: The human-readable error message.
    ///   - data: Optional structured error detail; omitted from the wire when
    ///     `nil`.
    case err(code: String, message: String, data: JSONValue?)
}
