public import Foundation

/// Claude Code's long-lived token from `claude setup-token` (`sk-ant-oat…`), as Settings > Models,
/// Settings > Cloud and the chat's Add account take it pasted (webviews' `claudeSetupToken.ts` checks
/// it the same way before it is sent).
public nonisolated struct ClaudeSetupToken {
    public nonisolated init() {}
    public static let prefix = "sk-ant-oat"
    /// The longest secret the app takes (a key, a token).
    public static let limit = 16_384

    /// TOKEN with every space, tab, line break and invisible space (zero-width, BOM) taken out. A setup
    /// token never holds whitespace, so a pasted one loses only what the copy added.
    public static func withoutWhitespace(_ secret: String) -> String {
        String(String.UnicodeScalarView(secret.unicodeScalars.filter { scalar in
            !scalar.properties.isWhitespace && !invisibleSpaces.contains(scalar.value)
        }))
    }

    /// Zero-width space, non-joiner, joiner, word joiner and BOM: not whitespace to Unicode, but a paste adds them.
    private static let invisibleSpaces: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]

    /// Whether TOKEN reads as a Claude setup token: `sk-ant-oat`, two digits, a dash, then base64url
    /// (letters, digits, `-`, `_`).
    public static func isValid(_ token: String) -> Bool {
        guard token.hasPrefix(prefix), token.utf8.count <= limit else { return false }
        let rest = Array(token.utf8.dropFirst(prefix.utf8.count))
        guard rest.count > 3, rest[0] >= 0x30, rest[0] <= 0x39, rest[1] >= 0x30, rest[1] <= 0x39, rest[2] == 0x2D else { return false }
        return rest.dropFirst(3).allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }
}

/// Where the chat's Add account puts a setup token: the login Keychain, written by acpmux itself
/// (`_acpmux/connections/secret.store`, as Settings > Models' `KeychainModelKeyStore` does), so the item
/// trusts acpmux and not `/usr/bin/security`. acpmux gets back only its `keychain:SERVICE/ACCOUNT`
/// reference; the token goes only over acpmux's unix socket.
protocol ClaudeTokenStoring: Sendable {
    /// Stores TOKEN; answers its `keychain:` reference.
    func store(_ token: String, socket: String) async throws -> String
    /// Takes a stored token back out by its reference (an add acpmux refused).
    func delete(_ reference: String, socket: String) async
}

struct AcpmuxClaudeTokenStore: ClaudeTokenStoring {
    func store(_ token: String, socket: String) async throws -> String {
        let account = "claude-token-\(UUID().uuidString.lowercased().prefix(8))"
        let reply = try await AcpmuxStatusClient.call(socketPath: socket, method: AcpmuxHarnessMethod.connectionsSecretStore.rawValue,
                                                      params: ["account": account, "label": "cmux claude-token API key", "secret": token],
                                                      deadline: .seconds(20), detailed: true)
        guard let reference = reply["secret"] as? String, reference.hasPrefix("keychain:") else {
            throw AcpmuxStatusClient.Failure.rpc("the token could not be stored in the Keychain")
        }
        return reference
    }

    func delete(_ reference: String, socket: String) async {
        // acpmux's reference is `keychain:SERVICE/ACCOUNT`; `secret.delete` removes only an item
        // `secret.store` wrote, by its account.
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false)
        guard reference.hasPrefix("keychain:"), parts.count == 2, !parts[1].isEmpty else { return }
        let account = String(parts[1])
        _ = try? await AcpmuxStatusClient.call(socketPath: socket, method: AcpmuxHarnessMethod.connectionsSecretDelete.rawValue,
                                               params: ["account": account], deadline: .seconds(20), detailed: true)
    }
}
