internal import Foundation

extension ControlCommandCoordinator {
    private static let workspaceFontSizeAllowedParams: Set<String> = [
        "action", "window_id", "workspace_id",
    ]

    private static let workspaceFontSizeFallbackStrings = ControlWorkspaceFontSizeStrings(
        invalidParams: "Invalid workspace font-size parameters",
        unavailable: "Workspace font-size unavailable",
        notFound: "Workspace not found",
        rejected: "Workspace font-size request rejected"
    )

    /// Handles `workspace.font_size` after validating the complete request
    /// envelope. Selector validation is deliberately stricter than the shared
    /// UUID resolver: a window selector may only be a UUID or a `window:` ref,
    /// and a workspace selector may only be a UUID or a `workspace:` ref.
    func workspaceFontSize(_ params: [String: JSONValue]) -> ControlCallResult {
        guard params.keys.allSatisfy(Self.workspaceFontSizeAllowedParams.contains),
              let rawAction = string(params, "action"),
              let action = ControlWorkspaceFontSizeAction(rawValue: rawAction),
              validWorkspaceFontSizeSelector(params, key: "window_id", kind: .window),
              validWorkspaceFontSizeSelector(params, key: "workspace_id", kind: .workspace)
        else {
            return .err(
                code: "invalid_params",
                message: context?.controlWorkspaceFontSizeStrings().invalidParams
                    ?? Self.workspaceFontSizeFallbackStrings.invalidParams,
                data: nil
            )
        }

        guard let context else {
            return .err(
                code: "unavailable",
                message: Self.workspaceFontSizeFallbackStrings.unavailable,
                data: nil
            )
        }

        let strings = context.controlWorkspaceFontSizeStrings()
        switch context.controlWorkspaceFontSize(
            routing: routingSelectors(params),
            action: action
        ) {
        case .unavailable:
            return .err(code: "unavailable", message: strings.unavailable, data: nil)
        case .notFound:
            return .err(code: "not_found", message: strings.notFound, data: nil)
        case .rejected:
            return .err(code: "invalid_state", message: strings.rejected, data: nil)
        case .accepted(let workspaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "action": .string(action.rawValue),
                "accepted": .bool(true),
            ]))
        }
    }

    /// Checks presence and type independently from `uuid(_:_:)`, so an
    /// explicit JSON null, blank value, unknown ref, or wrong-kind ref cannot
    /// silently turn into an absent routing selector.
    private func validWorkspaceFontSizeSelector(
        _ params: [String: JSONValue],
        key: String,
        kind: ControlHandleKind
    ) -> Bool {
        guard let rawValue = params[key] else { return true }
        guard case .string(let raw) = rawValue else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if UUID(uuidString: trimmed) != nil {
            return true
        }
        guard trimmed.hasPrefix(kind.rawValue + ":") else { return false }
        return uuid(params, key) != nil
    }
}
