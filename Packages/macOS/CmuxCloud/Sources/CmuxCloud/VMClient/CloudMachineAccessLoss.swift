import Foundation

/// Classifies control-plane answers that mean the signed-in user can no longer
/// reach a Cloud machine.
///
/// A permanent loss ends automatic reconnects: retrying cannot succeed until
/// the user regains access, and a pane that keeps retrying would only show a
/// frozen frame. Transient failures (timeouts, 5xx, throttling, transport
/// errors) are never permanent.
///
/// ```swift
/// if CloudMachineAccessLoss(error: error) != nil {
///     provider.noteAccessLost()
/// }
/// ```
public enum CloudMachineAccessLoss: Equatable, Sendable {
    /// The machine no longer exists for this user (`404 vm_not_found`).
    case notFound
    /// The user is no longer allowed to use the machine (`403`), including
    /// removal from the machine's team.
    case forbidden
    /// The machine belongs to an owner the request is not authorized for
    /// (`vm_owner_mismatch`, any status).
    case ownerMismatch

    /// Classifies `error`; nil when it is not a permanent access loss.
    ///
    /// - Parameter error: An error thrown by ``VMClient``.
    public init?(error: Error) {
        guard case let VMClientError.httpStatus(status, body) = error else { return nil }
        self.init(status: status, body: body)
    }

    /// Classifies an HTTP status and response body; nil when transient.
    ///
    /// - Parameters:
    ///   - status: The HTTP status code.
    ///   - body: The response body, whose JSON `error` field carries the code.
    public init?(status: Int, body: String) {
        let code = Self.errorCode(body)
        if code == "vm_owner_mismatch" {
            self = .ownerMismatch
        } else if status == 403 {
            self = .forbidden
        } else if status == 404, code == "vm_not_found" {
            self = .notFound
        } else {
            return nil
        }
    }

    private static func errorCode(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
