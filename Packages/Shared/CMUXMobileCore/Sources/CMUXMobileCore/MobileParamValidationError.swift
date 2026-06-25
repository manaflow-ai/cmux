/// A typed, value-only description of a failed mobile-RPC param validation.
///
/// The mobile data plane rejects malformed identifier params (an unparseable
/// terminal alias, conflicting alias keys, or a malformed `workspace_id`) with
/// an `invalid_params` error. The wire error carries a stable machine `code`
/// plus a human message. Both halves of the *meaning* live here so validation
/// can be classified and tested without a live connection; the human message
/// text itself stays on the Mac (it is `String(localized:)`-resolved against the
/// app bundle), so this value carries only the message KEY, never the localized
/// string.
///
/// The app maps a `MobileParamValidationError` to its localized `invalid_params`
/// error at the RPC seam via a single adapter, keeping every non-English
/// translation app-side where the catalog lives.
public struct MobileParamValidationError: Sendable, Equatable {
    /// The stable machine error code sent on the wire (always `invalid_params`
    /// for these validations).
    public let code: String

    /// Which human message the app should localize for this failure. The
    /// English text and its translations live in the app bundle; this is only
    /// the selector.
    public let messageKey: MessageKey

    public init(code: String, messageKey: MessageKey) {
        self.code = code
        self.messageKey = messageKey
    }

    /// Identifies the human message for a mobile param-validation failure.
    ///
    /// Each case corresponds to one app-side `String(localized:)` entry. The
    /// package never holds the English text or its translations; it only names
    /// which message a given classification produces.
    public enum MessageKey: Sendable, Equatable {
        /// A terminal alias key was missing or its value was not a valid UUID.
        case missingOrInvalidTerminalID
        /// Two or more terminal alias keys disagreed.
        case conflictingTerminalIdentifiers
        /// A `workspace_id` param was present but was not a valid UUID.
        case missingOrInvalidWorkspaceID
    }

    /// The standard `invalid_params` error for a malformed/missing terminal alias.
    public static let missingOrInvalidTerminalID = MobileParamValidationError(
        code: "invalid_params",
        messageKey: .missingOrInvalidTerminalID
    )

    /// The standard `invalid_params` error for conflicting terminal alias keys.
    public static let conflictingTerminalIdentifiers = MobileParamValidationError(
        code: "invalid_params",
        messageKey: .conflictingTerminalIdentifiers
    )

    /// The standard `invalid_params` error for a malformed `workspace_id`.
    public static let missingOrInvalidWorkspaceID = MobileParamValidationError(
        code: "invalid_params",
        messageKey: .missingOrInvalidWorkspaceID
    )
}
