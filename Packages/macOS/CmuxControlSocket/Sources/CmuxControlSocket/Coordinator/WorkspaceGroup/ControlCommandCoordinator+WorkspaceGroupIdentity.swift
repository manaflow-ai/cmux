internal import CmuxCore
internal import Foundation

extension ControlCommandCoordinator {
    /// Parses the two accepted spellings for a caller-owned group identity.
    /// `external_id` is the durable model name; `idempotency_key` is the
    /// standard retry-oriented alias. Supplying both is allowed only when they
    /// agree exactly after trimming.
    func workspaceGroupExternalID(
        _ params: [String: JSONValue]
    ) -> (value: String?, error: ControlCallResult?) {
        do {
            let resolution = try WorkspaceGroupIdentityResolution(
                externalID: workspaceGroupIdentityInput(params["external_id"]),
                idempotencyKey: workspaceGroupIdentityInput(params["idempotency_key"])
            )
            return (resolution.value, nil)
        } catch let error as WorkspaceGroupIdentityResolution.ValidationError {
            switch error {
            case .nonString(let field):
                return (nil, .err(
                    code: "invalid_params",
                    message: workspaceGroupStrings().idempotencyKeyMustBeString,
                    data: .object(["field": .string(field.rawValue)])
                ))
            case .empty(let field):
                return (nil, .err(
                    code: "invalid_params",
                    message: workspaceGroupStrings().idempotencyKeyMustNotBeEmpty,
                    data: .object(["field": .string(field.rawValue)])
                ))
            case .mismatchedAliases:
                return (nil, .err(
                    code: "invalid_params",
                    message: workspaceGroupStrings().idempotencyKeysMustMatch,
                    data: nil
                ))
            }
        } catch {
            assertionFailure("Unexpected workspace-group identity validation error: \(error)")
            return (nil, .err(
                code: "invalid_params",
                message: workspaceGroupStrings().idempotencyKeyMustBeString,
                data: nil
            ))
        }
    }

    private func workspaceGroupIdentityInput(
        _ value: JSONValue?
    ) -> WorkspaceGroupIdentityResolution.Input {
        guard let value else { return .absent }
        if case .null = value { return .absent }
        guard case .string(let raw) = value else { return .invalid }
        return .string(raw)
    }
}
