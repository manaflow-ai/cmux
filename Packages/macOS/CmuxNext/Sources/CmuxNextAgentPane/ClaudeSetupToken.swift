import CmuxNextPages
import CmuxNextWakeups
public import Foundation

/// Claude Code's long-lived token from `claude setup-token` (`sk-ant-oat…`), as Settings > Models,
/// Settings > Cloud and the chat's Add account take it pasted (webviews' `claudeSetupToken.ts` checks
/// it the same way before it is sent).
public nonisolated enum ClaudeSetupToken {
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

/// Where a pasted model API key goes on this Mac: the Keychain, before acpmux hears of it. acpmux gets
/// only the returned reference (`keychain:SERVICE/ACCOUNT`) and resolves it itself at each request.
public protocol ModelKeyStoring: Sendable {
    /// Stores KEY for PROVIDER; answers its `keychain:` reference.
    func store(_ key: String, provider: String) async throws -> String
    /// Removes a stored key by its reference (a connection that was never added).
    func delete(_ reference: String) async
}

/// The login Keychain through `/usr/bin/security`, as acpmux's own `cmux harness secret set` stores
/// one (cli/harness_secret.rs): the item's creator is `security`, so acpmux's
/// `security find-generic-password` reads it without a prompt. The key goes only to the tool's
/// standard input (`security -i`), never its arguments, and its output (which can echo the line) is
/// dropped.
public struct KeychainModelKeyStore: ModelKeyStoring {
    public static let service = "cmux-model-key"

    public init() {}

    public func store(_ key: String, provider: String) async throws -> String {
        let account = "\(provider)-\(UUID().uuidString.lowercased().prefix(8))"
        let line = "add-generic-password -U -s \(Self.quoted(Self.service)) -a \(Self.quoted(account)) "
            + "-l \(Self.quoted("cmux \(provider) API key")) -w \(Self.quoted(key))\n"
        let ran = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"), ["-i"],
                                                              input: Data(line.utf8), errorOutput: .discard, timeout: .seconds(30), onCancel: .finish))
        guard ran.succeeded else { throw PageError(code: "cmux.models.keychain", message: "the key could not be stored in the Keychain") }
        return "keychain:\(Self.service)/\(account)"
    }

    public func delete(_ reference: String) async {
        let prefix = "keychain:\(Self.service)/"
        guard reference.hasPrefix(prefix) else { return }
        let account = String(reference.dropFirst(prefix.count))
        guard !account.isEmpty, !account.contains("/") else { return }
        _ = try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"),
                                                         ["delete-generic-password", "-s", Self.service, "-a", account],
                                                         errorOutput: .discard, timeout: .seconds(30)))
    }

    /// One `security -i` word: quoted, with `\` and `"` escaped.
    nonisolated static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
