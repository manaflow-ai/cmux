/// The outcome of validating the `workspace_id` param of a mobile RPC.
///
/// The mobile data plane treats `workspace_id` as optional, but if it is present
/// it must be a well-formed UUID (or a resolvable ref). This enum is the pure,
/// value-typed classification of that single check: either the param is
/// acceptable (absent, or present and well-formed) or it is present-but-invalid.
///
/// The classification itself stays on the Mac (it reads app-side v2 param
/// helpers); only this result shape, and its mapping to a typed validation
/// error, live here in the shared mobile value-type domain.
public enum MobileWorkspaceIDValidation: Sendable, Equatable {
    /// The `workspace_id` param is acceptable: either absent, or present and a
    /// well-formed UUID/ref.
    case ok
    /// The `workspace_id` param was present but was not a valid UUID/ref.
    case invalid
}

extension MobileWorkspaceIDValidation {
    /// The typed `invalid_params` error this result should produce, or `nil`
    /// when the param is acceptable.
    ///
    /// The app maps the returned error to a localized wire response; the package
    /// only names the failure.
    public var validationError: MobileParamValidationError? {
        switch self {
        case .ok:
            return nil
        case .invalid:
            return .missingOrInvalidWorkspaceID
        }
    }
}

extension MobileTerminalAliasUUID {
    /// The typed `invalid_params` error this resolution should produce, or `nil`
    /// when no alias error is present.
    ///
    /// `.missing` and `.value` are acceptable (the caller decides whether a
    /// terminal is required); only a malformed alias (`.invalid`) or disagreeing
    /// alias keys (`.conflict`) are validation errors. The app maps the returned
    /// error to a localized wire response; the package only names the failure.
    public var validationError: MobileParamValidationError? {
        switch self {
        case .missing, .value:
            return nil
        case .invalid:
            return .missingOrInvalidTerminalID
        case .conflict:
            return .conflictingTerminalIdentifiers
        }
    }
}
