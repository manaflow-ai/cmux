import CmuxNextDaemon
import CryptoKit
import Foundation
import Security

/// The transfer cache uses #25488's cmux-cloud-secret Keychain service and its stdin-only
/// `cloud secret set` API. It is separate from the user's normal Claude/Codex login/cache.
@MainActor enum CloudCredentialLogin {
    typealias Failure = CloudCredentialTransfer.Failure
    typealias Provider = CloudCredentialTransfer.Provider

    nonisolated static func name(provider: Provider, teamID: String, userID: String) -> String {
        let scope = SHA256.hash(data: Data((userID + ":" + teamID).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue.uppercased())_TRANSFER_\(scope)"
    }

    @concurrent static func load(provider: Provider, teamID: String, userID: String) async throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "cmux-cloud-secret",
            kSecAttrAccount: "*/" + name(provider: provider, teamID: teamID, userID: userID),
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let created = object["created"] as? Double,
              created > 0,
              let encoded = object["credential"] as? String, let data = Data(base64Encoded: encoded)
        else { if status == errSecSuccess { return nil }; throw Failure.storeFailed }
        try CloudCredentialTransfer.validate(data, provider: provider)
        return data
    }

    static func store(_ value: Data, provider: Provider, teamID: String, userID: String) async throws {
        guard let binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: [:]) else { throw Failure.storeFailed }
        let envelope = try JSONSerialization.data(withJSONObject: [
            "created": Date().timeIntervalSince1970, "credential": value.base64EncodedString(),
        ])
        // The underlying store's 16 KiB bound applies to the compact envelope too.
        guard envelope.count <= 16_384 else { throw Failure.invalidCredential }
        let result = try await ProcessRunner.run(executable: binary,
            arguments: ["cloud", "secret", "set", name(provider: provider, teamID: teamID, userID: userID)],
            environment: nil, stdin: envelope, timeout: .seconds(70), clock: ContinuousClock())
        guard result.status == 0 else { throw Failure.storeFailed }
    }

    static func acquire(provider: Provider, openTerminal: @MainActor (String) -> Bool) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-credential-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // The visible terminal owns the provider process. Do not remove this directory while a
        // cancelled login may still be writing it; the shell's private umask and no shared path
        // keep a cancelled attempt unreadable. Completed attempts clean up below.
        let script = directory.appendingPathComponent("login.sh")
        try Data(loginScript(provider: provider, directory: directory).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard openTerminal("/bin/bash " + CloudCredentialInstaller.quote(script.path)) else { throw Failure.localLoginUnavailable }
        let status = directory.appendingPathComponent("status")
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let code = try? String(contentsOf: status, encoding: .utf8) {
                guard code.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { throw Failure.loginFailed }
                let value = try Data(contentsOf: directory.appendingPathComponent(provider == .claude ? "output" : "auth.json"))
                if provider == .claude {
                    let token = try claudeToken(from: value)
                    try? FileManager.default.removeItem(at: directory)
                    return token
                }
                try CloudCredentialTransfer.validate(value, provider: provider)
                try? FileManager.default.removeItem(at: directory)
                return value
            }
            // condition-wait: the one visible login's private completion marker, bounded to 5 min.
            try await clock.sleep(for: .milliseconds(250))
        }
        throw Failure.loginFailed
    }

    nonisolated static func claudeToken(from output: Data) throws -> Data {
        guard output.count <= 262_144 else { throw Failure.invalidCredential }
        let text = String(decoding: output, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"sk-ant-oat01-[A-Za-z0-9_-]{20,}"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let tokens = Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        guard tokens.count == 1, let token = tokens.first else { throw Failure.invalidCredential }
        return Data(token.utf8)
    }

    nonisolated static func loginScript(provider: Provider, directory: URL) -> String {
        let dir = CloudCredentialInstaller.quote(directory.path)
        // Run from the private directory, never a repository that could inject provider settings.
        // setup-token prints its minted secret: keep ALL its output out of terminal transcripts.
        // Its browser opens normally; the parent UI displays progress while approval is pending.
        let command = provider == .claude
            ? "CLAUDE_CONFIG_DIR=\(dir)/claude claude setup-token >\(dir)/output 2>&1"
            : "CODEX_HOME=\(dir) codex -c 'cli_auth_credentials_store=\"file\"' login --device-auth"
        return """
            #!/bin/bash
            umask 077
            cd \(dir) || exit 1
            unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN
            unset OPENAI_API_KEY OPENAI_BASE_URL CODEX_API_KEY CODEX_ACCESS_TOKEN
            \(command)
            code=$?
            printf '%s' "$code" > \(dir)/status.tmp
            mv \(dir)/status.tmp \(dir)/status
            # A cancelled parent cannot own this visible terminal process; bound its lifetime and
            # remove the private scratch after the parent has had time to consume the marker.
            (sleep 300; rm -rf -- \(dir)) >/dev/null 2>&1 &
            """
    }
}
