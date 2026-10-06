import Foundation
@testable import CmuxNextCodeRouter

/// A throwaway home directory with fake credential files. Every value is a
/// made-up placeholder; nothing here is a real credential.
final class FixtureHome: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relative: String, _ text: String) throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func writeJSON(_ relative: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try write(relative, String(decoding: data, as: UTF8.self))
    }

    func environment(_ env: [String: String] = [:], keychain: Set<String> = [], servers: Set<String> = [],
                     savedKeys: Set<AIProvider> = [], now: Date = Date(timeIntervalSince1970: 1_900_000_000)) -> DetectionEnvironment {
        DetectionEnvironment(home: url, environment: env, files: LiveFileReader(), keychain: FakeKeychain(services: keychain),
                             servers: FakeServers(reachable: servers), labeler: fixtureLabeler, savedKeys: savedKeys, now: now)
    }
}

/// A fixed salt, so handles are reproducible in tests.
struct FixedSalt: AccountLabelSaltProviding {
    let bytes: Data
    func salt() throws -> Data { bytes }
}

let fixtureSalt = Data((0..<32).map { UInt8($0) })
let fixtureLabeler = AccountLabeler(salt: fixtureSalt)

struct FakeKeychain: KeychainProbing {
    let services: Set<String>
    func hasGenericPassword(service: String) -> Bool { services.contains(service) }
}

struct FakeServers: LocalServerProbing {
    let reachable: Set<String>
    func isReachable(_ url: URL) async -> Bool { reachable.contains(url.absoluteString) }
}

/// In-memory ``ProviderKeyStoring``.
final class FakeKeyStore: ProviderKeyStoring, @unchecked Sendable {
    private var keys: [AIProvider: String]
    init(_ keys: [AIProvider: String] = [:]) { self.keys = keys }
    func savedProviders() -> Set<AIProvider> { Set(keys.keys) }
    func save(_ key: String, for provider: AIProvider) throws { keys[provider] = key }
    func key(for provider: AIProvider) throws -> String? { keys[provider] }
    func delete(for provider: AIProvider) throws { keys[provider] = nil }
}

/// An unsigned JWT with `claims` (shape only; tests never verify it).
func fakeJWT(_ claims: [String: Any]) -> String {
    func encode(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return encode(["alg": "none"]) + "." + encode(claims) + ".fake-signature"
}

/// A Codex `auth.json` with ChatGPT tokens.
/// A Codex `auth.json`. `workspace` and `user` are the ChatGPT workspace and
/// user id claims (nil leaves the claim out); `tokens.account_id` is the
/// workspace, as the CLI writes it.
func codexAuth(email: String = "dev@example.com", plan: String = "pro", refresh: String = "fake-refresh-token",
               accessExpiry: Double = 1_900_003_600, workspace: String? = "acct-fixture", user: String? = "user-fixture") -> [String: Any] {
    var auth: [String: Any] = ["chatgpt_plan_type": plan]
    auth["chatgpt_account_id"] = workspace
    auth["chatgpt_user_id"] = user
    return [
        "OPENAI_API_KEY": NSNull(),
        "tokens": [
            "id_token": fakeJWT(["email": email, "https://api.openai.com/auth": auth]),
            "access_token": fakeJWT(["exp": accessExpiry]),
            "refresh_token": refresh,
            "account_id": workspace.map { $0 as Any } ?? NSNull(),
        ],
        "last_refresh": "2026-09-30T00:00:00Z",
    ]
}

/// The handle every side must give the Codex sign-in of `workspace` + `user`.
func codexHandle(workspace: String = "acct-fixture", user: String = "user-fixture") -> String {
    fixtureLabeler.handle(namespace: "codex", identity: "codex:workspace:\(workspace):user:\(user)")
}
