import CmuxControlSocket
import CmuxSettings
import Foundation

extension TerminalController {
    private nonisolated static var socketClientPreauthorizationLimits: ControlClientLineReadLimits {
        ControlClientLineReadLimits(
            maximumBytes: 4 * 1024 * 1024,
            timeoutMilliseconds: 2_000
        )
    }

    nonisolated static func makeSocketClientCapabilityAuthority(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> SocketClientCapabilityAuthority {
        let audience = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "com.cmuxterm.app"
        let store = SocketClientCapabilitySecretStore(
            service: "\(audience).socket-client-capability"
        )
        let usesEphemeralSecret = SocketControlSettings.isDebugLikeBundleIdentifier(audience)
            || SocketControlSettings.isStagingBundleIdentifier(audience)
        let secret = usesEphemeralSecret
            ? store.makeEphemeralSecret()
            : store.loadOrCreateSecret()
        return SocketClientCapabilityAuthority(secret: secret, audience: audience)
    }

    nonisolated func socketClientCapabilityEnvironment() -> [String: String] {
        [
            SocketClientCapabilityEnvelope.environmentKey:
                socketClientCapabilityAuthority.issueCapability()
        ]
    }

    nonisolated func socketClientInitialReadLimits(
        peerProcessID: pid_t?
    ) -> ControlClientLineReadLimits? {
        guard socketServer.accessMode == .cmuxOnly,
              !(peerProcessID.map(isDescendant) ?? false) else {
            return nil
        }
        return Self.socketClientPreauthorizationLimits
    }

    nonisolated func authorizedSocketCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool
    ) -> String? {
        if Self.isCodeRouterHandoffCommand(command), command.utf8.count > 4_096 {
            return nil
        }
        // A handoff lease is authority, so the permissive automation/allowAll
        // modes must not turn it into an unauthenticated local HTTP mint. Keep
        // the normal cmux-only ancestry or signed capability requirement in
        // those modes. Password mode is already gated by authResponseIfNeeded
        // immediately before this call.
        if Self.isCodeRouterHandoffCommand(command),
           Self.codeRouterHandoffRequiresCmuxOnly(for: socketServer.accessMode) {
            return SocketClientAuthorization().authorizedCommand(
                command,
                accessMode: .cmuxOnly,
                peerProcessID: peerProcessID,
                peerHasSameUID: peerHasSameUID,
                capabilityAuthority: socketClientCapabilityAuthority,
                isDescendant: { isDescendant($0) }
            )
        }
        return SocketClientAuthorization().authorizedCommand(
            command,
            accessMode: socketServer.accessMode,
            peerProcessID: peerProcessID,
            peerHasSameUID: peerHasSameUID,
            capabilityAuthority: socketClientCapabilityAuthority,
            isDescendant: { isDescendant($0) }
        )
    }

    nonisolated static func isCodeRouterHandoffCommand(_ command: String) -> Bool {
        let unwrapped = SocketClientCapabilityCommand(command)?.command ?? command
        // Do not use the normal small-request bound as a parsing shortcut.
        // The caller uses this predicate before applying the bound; returning
        // false for an oversized handoff would let permissive socket modes
        // treat a credential-bearing request as an ordinary command. The
        // socket reader already has a 4 MiB cap for preauthorization, so a
        // bounded JSON parse here is safe and keeps escaped method names
        // fail-closed as well.
        guard unwrapped.hasPrefix("{"),
              let data = unwrapped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let method = object["method"] as? String else {
            return false
        }
        return method == "coderouter.handoff"
    }

    nonisolated static func codeRouterHandoffRequiresCmuxOnly(
        for accessMode: SocketControlMode
    ) -> Bool {
        accessMode == .automation || accessMode == .allowAll
    }

    nonisolated func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    nonisolated func passwordLoginV1ResponseIfNeeded(
        for command: String,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> String? {
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
        passwordAuthorization.authenticate(password: provided)
        return "OK: Authenticated"
    }

    nonisolated func passwordLoginV2ResponseIfNeeded(
        for command: String,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> String? {
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
        passwordAuthorization.authenticate(password: provided)
        return v2Ok(id: id, result: ["authenticated": true])
    }

    nonisolated func authResponseIfNeeded(
        for command: String,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> String? {
        guard socketServer.accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(
            for: command,
            passwordAuthorization: &passwordAuthorization
        ) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(
            for: command,
            passwordAuthorization: &passwordAuthorization
        ) {
            return v1Response
        }
        if !passwordAuthorization.isAuthenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    /// Checks both listener policy generation and password credential revision.
    nonisolated func socketAuthorizationIsCurrent(
        _ authorizationGeneration: UInt64,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> Bool {
        socketServer.isConnectionAuthorizationCurrent(
            authorizationGeneration,
            passwordAuthorization: passwordAuthorization
        )
    }

    nonisolated func socketEventStreamAuthorizationIsCurrent(
        _ authorizationGeneration: UInt64,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> Bool {
        socketAuthorizationIsCurrent(
            authorizationGeneration,
            passwordAuthorization: &passwordAuthorization
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
