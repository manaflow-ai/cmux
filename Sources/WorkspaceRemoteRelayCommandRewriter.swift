import CmuxRemoteWorkspace
import CryptoKit
import Foundation

/// App-side conformance to the relay's command-rewrite seam: forwards to the
/// workspace model's alias-aware static rewrite so the package never imports
/// `Workspace`.
struct WorkspaceRemoteRelayCommandRewriter: RemoteRelayCommandRewriting {
    /// Legacy per-resume MAC key. Nothing verifies it anymore, but old remote
    /// clients may still send it, so it stays out of the signed request payload.
    static let authenticationCodeKey = "_cmux_remote_relay_authentication_code"
    static let requestAuthenticationCodeKey = "_cmux_remote_relay_request_authentication_code"
    static let remoteWorkspaceIDKey = "_cmux_remote_workspace_id"
    static let connectionIDKey = "_cmux_remote_connection_id"

    let remoteWorkspaceID: UUID
    let remoteRelayTokenHex: String
    var remoteSessionControllerID: UUID? = nil

    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        let rewritten = Workspace.rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases,
            remoteWorkspaceID: remoteWorkspaceID
        )
        return authenticatedRemoteRelayCommandLine(rewritten)
    }

    /// Verifies the relay-wide request MAC over the canonical envelope.  The
    /// caller supplies the decoded envelope fields so socket ingress and the
    /// relay rewriter share exactly one signing format.
    static func authenticatesRemoteRelayRequest(
        id: Any?,
        method: String,
        params: [String: Any],
        remoteRelayTokenHex: String?
    ) -> Bool {
        guard let remoteRelayTokenHex,
              let authenticationCode = params[requestAuthenticationCodeKey] as? String,
              let payload = requestAuthenticationPayload(id: id, method: method, params: params),
              let relayToken = hexData(remoteRelayTokenHex),
              let receivedCode = hexData(authenticationCode) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            receivedCode,
            authenticating: payload,
            using: SymmetricKey(data: relayToken)
        )
    }

    static func requestAuthenticationCode(
        id: Any?,
        method: String,
        params: [String: Any],
        remoteRelayTokenHex: String?
    ) -> String? {
        guard let remoteRelayTokenHex,
              let payload = requestAuthenticationPayload(id: id, method: method, params: params),
              let relayToken = hexData(remoteRelayTokenHex) else {
            return nil
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: relayToken)
        )
        return hexString(code)
    }

    private func authenticatedRemoteRelayCommandLine(_ commandLine: Data) -> Data {
        guard let line = String(data: commandLine, encoding: .utf8),
              let requestData = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return commandLine
        }
        var params = request["params"] as? [String: Any] ?? [:]
        // This is the local controller that accepted the authenticated relay,
        // never an identifier supplied by the remote client or an alias map.
        params[Self.connectionIDKey] = remoteSessionControllerID?.uuidString
        guard let authenticationCode = Self.requestAuthenticationCode(
            id: request["id"],
            method: method,
            params: params,
            remoteRelayTokenHex: remoteRelayTokenHex
        ) else {
            return commandLine
        }
        params[Self.requestAuthenticationCodeKey] = authenticationCode
        request["params"] = params
        guard let authenticated = try? JSONSerialization.data(withJSONObject: request) else {
            return commandLine
        }
        return commandLine.last == 0x0A ? authenticated + Data([0x0A]) : authenticated
    }

    private static func requestAuthenticationPayload(
        id: Any?,
        method: String,
        params: [String: Any]
    ) -> Data? {
        var authenticatedParams = params
        authenticatedParams.removeValue(forKey: authenticationCodeKey)
        authenticatedParams.removeValue(forKey: requestAuthenticationCodeKey)
        let envelope: [String: Any] = [
            "id": id ?? NSNull(),
            "method": method,
            "params": authenticatedParams,
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else { return nil }
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private static func hexData(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        var decoded = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1]) else { return nil }
            decoded.append((high << 4) | low)
            index += 2
        }
        return decoded
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }

    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
