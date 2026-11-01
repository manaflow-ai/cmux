import CmuxNextCompat
public import Foundation

/// The provider side of the DEBUG auth capture fixture (`CMUX_NEXT_AUTH_CAPTURE_FIXTURE`, AppEnvironment):
/// provider detection reads a virtual, empty provider home with no process environment, no Keychain and no
/// loopback model server; saved keys live in memory; account handles use a fixed salt. The App's
/// AccountsService holds one only while that DEBUG-only flag is on.
public struct ProviderCaptureFixture: Sendable {
    /// The provider home detection reads (never read: ``detectionEnvironment(labeler:)``'s files are empty).
    public let home = URL(fileURLWithPath: "/cmux-auth-capture/providers", isDirectory: true)
    /// The account labeler, from a fixed salt.
    public let labeler = AccountLabeler(salt: Data("cmux-auth-capture-label-salt".utf8))
    /// What a provider sign-in types in its terminal instead of the provider's login.
    public let terminalLine = "/usr/bin/printf 'Provider sign-in capture: local terminal opened\\n'"
    /// What a provider page opens instead of the provider's page.
    public let pageURL = URL(fileURLWithPath: "/dev/null")

    public init() {}

    /// A key store that keeps keys in memory, never in the Keychain.
    public func keys() -> any ProviderKeyStoring { MemoryKeyStore() }

    /// The label salt provider (the same fixed salt as ``labeler``).
    public var labelSalt: any AccountLabelSaltProviding { FixedSalt() }

    /// The detection inputs: the virtual home, no environment, no file, no Keychain, no local server, no saved key.
    public func detectionEnvironment(labeler: AccountLabeler) -> DetectionEnvironment {
        DetectionEnvironment(home: home, environment: [:], files: NoFiles(), keychain: NoKeychain(),
                             servers: NoLocalServer(), labeler: labeler, savedKeys: [])
    }
}

private final class MemoryKeyStore: ProviderKeyStoring, Sendable {
    private let values = Mutex<[AIProvider: String]>([:])

    func savedProviders() -> Set<AIProvider> { values.withLock { Set($0.keys) } }
    func save(_ key: String, for provider: AIProvider) throws { values.withLock { $0[provider] = key } }
    func key(for provider: AIProvider) throws -> String? { values.withLock { $0[provider] } }
    func delete(for provider: AIProvider) throws { _ = values.withLock { $0.removeValue(forKey: provider) } }
}

/// A virtual provider home: even an existing file at this path is never read.
private struct NoFiles: FileReading {
    func data(at url: URL) -> Data? { nil }
    func exists(_ url: URL) -> Bool { false }
}

private struct NoKeychain: KeychainProbing {
    func hasGenericPassword(service: String) -> Bool { false }
}

/// Provider detection must not probe a developer's loopback model servers.
private struct NoLocalServer: LocalServerProbing {
    func isReachable(_ url: URL) async -> Bool { false }
}

private struct FixedSalt: AccountLabelSaltProviding {
    func salt() throws -> Data { Data("cmux-auth-capture-label-salt".utf8) }
}
