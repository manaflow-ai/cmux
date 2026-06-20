public import CmuxSettings
internal import Foundation

/// The control-socket password handshake, lifted byte-faithfully from
/// `TerminalController`'s `authResponseIfNeeded` / `passwordLoginV1ResponseIfNeeded`
/// / `passwordLoginV2ResponseIfNeeded` / `passwordAuthRequiredResponse` helpers.
///
/// One source of truth shared by both legacy auth gates: the per-connection
/// read loop (``ControlClientConnectionHandler``, the `events.stream` branch)
/// and the per-command dispatcher (the app's `processSocketLine`). Both call
/// ``response(for:authenticated:)`` before running a command; the handler used
/// `handleClient`'s inline gate and the dispatcher used `processSocketLine`'s
/// gate, but the logic and wire format are identical, so they collapse here.
///
/// Stateless and `Sendable`: it carries the configured-password store and the
/// listener access mode by value, performs no I/O of its own beyond the store
/// lookups, and is safe to call from any client-handler thread.
public struct ControlPasswordAuthenticator: Sendable {
    private let passwordStore: SocketControlPasswordStore
    private let accessMode: SocketControlMode
    private let encoder: ControlResponseEncoder

    /// Creates an authenticator.
    /// - Parameters:
    ///   - passwordStore: Configured-password lookup and verification.
    ///   - accessMode: The listener access mode; password auth applies only
    ///     when ``SocketControlMode/requiresPasswordAuth`` is `true`.
    ///   - encoder: The v2 wire encoder for JSON auth responses; defaults to a
    ///     fresh stateless encoder.
    public init(
        passwordStore: SocketControlPasswordStore,
        accessMode: SocketControlMode,
        encoder: ControlResponseEncoder = ControlResponseEncoder()
    ) {
        self.passwordStore = passwordStore
        self.accessMode = accessMode
        self.encoder = encoder
    }

    /// The result of evaluating one line against the password gate.
    public struct Decision: Sendable {
        /// The response to write and stop processing the line, or `nil` when
        /// the caller should continue to the command body.
        public let response: String?
        /// The authentication state after evaluating the line.
        public let authenticated: Bool
    }

    /// Evaluates `command` against the password handshake.
    ///
    /// Returns a non-`nil` ``Decision/response`` (and stops command
    /// processing) when the line is an auth attempt or when an unauthenticated
    /// client must authenticate first; returns `nil` ``Decision/response``
    /// (letting the command run) when the mode requires no auth or the client
    /// is already authenticated and this line is not an auth attempt.
    /// - Parameters:
    ///   - command: The trimmed client line.
    ///   - authenticated: Whether the client has already authenticated.
    /// - Returns: The response and updated authentication state.
    public func response(for command: String, authenticated: Bool) -> Decision {
        var authenticated = authenticated
        guard accessMode.requiresPasswordAuth else {
            return Decision(response: nil, authenticated: authenticated)
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return Decision(response: v2Response, authenticated: authenticated)
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return Decision(response: v1Response, authenticated: authenticated)
        }
        if !authenticated {
            return Decision(response: passwordAuthRequiredResponse(for: command), authenticated: authenticated)
        }
        return Decision(response: nil, authenticated: authenticated)
    }

    private func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    // MARK: - Wire encoding (auth responses)

    /// Encodes a v2 error response for a Foundation `Any?` id, byte-identical
    /// to the legacy `TerminalController.v2Error(id:code:message:data:)`.
    private func v2Error(id: Any?, code: String, message: String, data: Any? = nil) -> String {
        guard let idValue = Self.wireId(id) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        var dataValue: JSONValue?
        if let data {
            guard let bridgedData = JSONValue(foundationObject: data) else {
                return ControlResponseEncoder.encodeFailureResponse
            }
            dataValue = bridgedData
        }
        return encoder.error(id: idValue, code: code, message: message, data: dataValue)
    }

    /// Encodes a v2 ok response for a Foundation `Any?` id and result,
    /// byte-identical to the legacy `TerminalController.v2Ok(id:result:)`.
    private func v2Ok(id: Any?, result: Any) -> String {
        guard let idValue = Self.wireId(id),
              let payload = JSONValue(foundationObject: result) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return encoder.ok(id: idValue, result: payload)
    }

    /// Bridges a legacy `Any?` request id to the wire value: missing ids encode
    /// as JSON `null`; an unencodable id reports overall encode failure (the
    /// legacy `v2WireId` behavior).
    private static func wireId(_ id: Any?) -> JSONValue? {
        guard let id else { return .null }
        return JSONValue(foundationObject: id)
    }
}
