public import Foundation

/// Everything detection reads: a home directory, an environment (the
/// login shell's, so keys exported in `.zshrc` count), files, the
/// Keychain, local servers and the clock; and the labeler that turns a
/// signed-in identity into an ``AccountLabel``.
public struct DetectionEnvironment: Sendable {
    public var home: URL
    public var environment: [String: String]
    public var files: any FileReading
    public var keychain: any KeychainProbing
    public var servers: any LocalServerProbing
    /// Providers with a key in cmux's own Keychain item.
    public var savedKeys: Set<AIProvider>
    public var labeler: AccountLabeler
    public var now: Date

    public init(home: URL, environment: [String: String], files: any FileReading, keychain: any KeychainProbing,
                servers: any LocalServerProbing, labeler: AccountLabeler, savedKeys: Set<AIProvider> = [], now: Date = Date()) {
        self.home = home
        self.labeler = labeler
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.servers = servers
        self.savedKeys = savedKeys
        self.now = now
    }

    /// A non-empty environment value, else nil.
    func value(_ key: String) -> String? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// A path from the environment (with `~` expanded), else `fallback` under home.
    func directory(_ key: String, fallback: String) -> URL {
        if let raw = value(key) { return URL(fileURLWithPath: expand(raw), isDirectory: true) }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }

    func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }

    /// `url` as shown to the user: under home it starts with `~`, and an
    /// email in a file or folder name is shortened.
    func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return EmailRedaction.redactEmails(in: path) }
        return EmailRedaction.redactEmails(in: "~" + path.dropFirst(homePath.count))
    }

    /// A JSON object file, or nil when missing or not an object.
    func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = files.data(at: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
