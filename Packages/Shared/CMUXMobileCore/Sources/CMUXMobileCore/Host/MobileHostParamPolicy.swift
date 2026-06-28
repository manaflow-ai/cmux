import Foundation

/// The pure param-validation and gating decisions the Mac's mobile data-plane
/// RPC host makes about a v2 request's identifier params, with no app types.
///
/// Stateless: construct one inline wherever a decision is needed; every instance
/// applies the same rules. The app performs the `[String: Any]` extraction (the
/// v2 `hasNonNullParam` presence checks, the `v2UUID` parse, the
/// ``MobileTerminalAliasUUID`` classification) and constructs the wire
/// `V2CallResult`; this type owns only the decision between them, returning a
/// ``MobileHostRequestError`` the app maps back to a result.
public struct MobileHostParamPolicy: Sendable {
    /// Creates the policy. It is stateless.
    public init() {}

    /// Whether a present-but-malformed `workspace_id` should be rejected.
    ///
    /// A mutating handler rejects a `workspace_id` that is present and non-null
    /// but does not resolve to a UUID; a missing param is not an error here (the
    /// caller separately requires presence where it matters). ``parsesToUUID`` is
    /// evaluated lazily and only when ``present`` is `true`, preserving the
    /// original `guard present, v2UUID == nil` short-circuit: the app's UUID
    /// resolve is not a pure dict read (a present non-UUID string triggers a
    /// main-actor hop and a control-handle lookup), so an absent param must never
    /// trigger that resolve.
    ///
    /// - Parameters:
    ///   - present: Whether the `workspace_id` key was present and non-null.
    ///   - parsesToUUID: Lazily resolves whether the present value parses to a
    ///     UUID. Invoked at most once, and only when ``present`` is `true`.
    /// - Returns: ``MobileHostRequestError/invalidWorkspaceID`` when the param is
    ///   present but unresolvable, otherwise `nil`.
    public func workspaceIDError(present: Bool, parsesToUUID: () -> Bool) -> MobileHostRequestError? {
        guard present, !parsesToUUID() else { return nil }
        return .invalidWorkspaceID
    }

    /// Maps a classified terminal-alias outcome to a request error.
    ///
    /// ``MobileTerminalAliasUUID/missing`` and ``MobileTerminalAliasUUID/value(_:)``
    /// are accepted (no error); ``MobileTerminalAliasUUID/invalid`` and
    /// ``MobileTerminalAliasUUID/conflict`` are rejected.
    ///
    /// - Parameter alias: The classified terminal-alias triple.
    /// - Returns: The matching rejection, or `nil` when the alias is acceptable.
    public func terminalAliasError(_ alias: MobileTerminalAliasUUID) -> MobileHostRequestError? {
        switch alias {
        case .missing, .value:
            return nil
        case .invalid:
            return .invalidTerminalID
        case .conflict:
            return .conflictingTerminalIDs
        }
    }

    /// Whether a raw `workspace.action` value is one the mobile data plane may run.
    ///
    /// Defers to ``MobileWorkspaceAction/isMobileAllowed(_:)`` so the gate and the
    /// handler can never disagree on the allow-list or its normalization.
    ///
    /// - Parameter rawAction: The raw `action` param value, or `nil`.
    /// - Returns: `true` when the normalized action is mobile-allowed.
    public func allowsWorkspaceAction(_ rawAction: String?) -> Bool {
        MobileWorkspaceAction.isMobileAllowed(rawAction)
    }

    /// Trims a raw param string and returns it only when non-empty.
    ///
    /// - Parameter raw: The raw string value, or `nil`.
    /// - Returns: The whitespace-trimmed value when it is non-empty, otherwise
    ///   `nil`.
    public func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
