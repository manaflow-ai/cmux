import CmuxRemoteWorkspace
import CryptoKit
import Foundation

/// App-side conformance to the relay's command-rewrite seam: forwards to the
/// workspace model's alias-aware static rewrite so the package never imports
/// `Workspace`.
struct WorkspaceRemoteRelayCommandRewriter: RemoteRelayCommandRewriting {
    private static let authenticationCodeKey = "_cmux_remote_relay_authentication_code"

    let remoteWorkspaceID: UUID
    let remoteRelayTokenHex: String

    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        let rewritten = Workspace.rewriteRemoteRelayCommandLineAndExtractMethod(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases,
            remoteWorkspaceID: remoteWorkspaceID
        )
        // Method classification is a trust boundary; decoded JSON honors escapes that raw bytes do not.
        guard rewritten.method == "surface.resume.set" else { return rewritten.commandLine }
        return authenticatedRemoteResumeCommandLine(rewritten.commandLine)
    }

    static func authenticatesRemoteResumeParameters(
        _ params: [String: Any],
        remoteRelayTokenHex: String?
    ) -> Bool {
        guard let remoteRelayTokenHex,
              let authenticationCode = params[authenticationCodeKey] as? String,
              let payload = authenticationPayload(params),
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

    private func authenticatedRemoteResumeCommandLine(_ commandLine: Data) -> Data {
        guard let line = String(data: commandLine, encoding: .utf8),
              let requestData = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              request["method"] as? String == "surface.resume.set",
              var params = request["params"] as? [String: Any],
              let payload = Self.authenticationPayload(params),
              let relayToken = Self.hexData(remoteRelayTokenHex) else {
            return commandLine
        }
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: payload,
            using: SymmetricKey(data: relayToken)
        )
        params[Self.authenticationCodeKey] = Self.hexString(authenticationCode)
        request["params"] = params
        guard let authenticated = try? JSONSerialization.data(withJSONObject: request) else {
            return commandLine
        }
        return commandLine.last == 0x0A ? authenticated + Data([0x0A]) : authenticated
    }

    private static func authenticationPayload(_ params: [String: Any]) -> Data? {
        var authenticatedParams = params
        authenticatedParams.removeValue(forKey: authenticationCodeKey)
        guard JSONSerialization.isValidJSONObject(authenticatedParams) else { return nil }
        return try? JSONSerialization.data(withJSONObject: authenticatedParams, options: [.sortedKeys])
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
