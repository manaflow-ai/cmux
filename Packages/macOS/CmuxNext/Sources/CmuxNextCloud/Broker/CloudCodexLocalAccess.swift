import Darwin
public import Foundation

/// The access token the Mac's own Codex CLI keeps in its `auth.json` (Leo, 2026-11-05: "claude/codex/
/// antigravity/cursor/muse and those subscriptions should all be detectable / many many existing apps
/// can do this"), so a Mac already signed in to Codex gives its own Cloud machines access with no new
/// device login.
///
/// Read only, never a second refresher: Codex's refresh token rotates, and a second holder refreshing
/// it would invalidate the Mac's copy and sign the person out of Codex on the Mac. So this never runs
/// Codex against the Mac's home, never refreshes, never writes, and returns only the access token, the
/// account and the expiry (the same access-only shape the broker delivers). The Mac's Codex renews its
/// own token as the person uses it; a token too close to its end is not offered, and the broker's own
/// holder (or its device login) takes over.
///
/// Only the file store is read (`cli_auth_credentials_store` unset or `"file"`): in keyring or auto
/// mode the file may be stale and the Keychain item is Codex's own, so nothing is offered.
public nonisolated struct CloudCodexLocalAccess: Sendable {
    /// The Codex home this reads (``home(environment:userHome:)``).
    public let home: URL

    public init(home: URL) { self.home = home }

    /// A token with less left than this is not offered: the machine would need a renewal at once.
    public static let minimumLifetime: TimeInterval = 15 * 60
    /// `auth.json` is a few KiB; anything larger is not Codex's.
    static let sizeLimit = 64 * 1024

    /// The Codex home: `$CODEX_HOME` when set, else `~/.codex`.
    public static func home(environment: [String: String], userHome: URL) -> URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = raw.hasPrefix("~/") ? userHome.appendingPathComponent(String(raw.dropFirst(2))).path : raw
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true) }
        }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The Mac's current Codex access, or nil when there is none cmux may use: no ChatGPT sign-in, an
    /// API key sign-in, keyring storage, a file that is not the person's private regular file, or a
    /// token with less than ``minimumLifetime`` left. Blocking file IO: call it off the main actor.
    public func read(now: Date = Date()) -> CloudCodexAccessGrant? {
        guard Self.usesFileStore(config: home.appendingPathComponent("config.toml")),
              let data = Self.privateFile(home.appendingPathComponent("auth.json")) else { return nil }
        return Self.grant(authJSON: data, now: now)
    }

    /// The access-only grant in an `auth.json`'s bytes (pure; tests pass fixtures).
    static func grant(authJSON data: Data, now: Date) -> CloudCodexAccessGrant? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // An API key sign-in is not a subscription; a mode other than ChatGPT is not this reader's.
        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { return nil }
        if let mode = root["auth_mode"] as? String, mode != "chatgpt" { return nil }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty, access.utf8.count < 16_384,
              access.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let account = (tokens["account_id"] as? String) ?? accountClaim(access), !account.isEmpty,
              let expiry = expiry(access, now: now) else { return nil }
        guard expiry.timeIntervalSince(now) >= minimumLifetime else { return nil }
        return CloudCodexAccessGrant(accessToken: access, chatgptAccountID: account, expiresAt: expiry)
    }

    /// Whether config.toml keeps Codex's credentials in `auth.json` (its default).
    static func usesFileStore(config: URL) -> Bool {
        var info = stat()
        // No config.toml: Codex's default, the file store. One cmux cannot read: nothing is offered.
        if lstat(config.path, &info) != 0 { return errno == ENOENT }
        guard let data = privateFile(config, requirePrivate: false), let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "cli_auth_credentials_store" else { continue }
            let value = parts[1].split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == "file"
        }
        return true
    }

    /// A regular file of this user's, not a symlink, within ``sizeLimit``; `requirePrivate` also
    /// requires no group or other access (Codex writes `auth.json` 0600).
    static func privateFile(_ url: URL, requirePrivate: Bool = true) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              !requirePrivate || info.st_mode & 0o077 == 0, Int(info.st_size) <= sizeLimit,
              let data = try? handle.read(upToCount: sizeLimit + 1), data.count <= sizeLimit else { return nil }
        return data
    }

    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ jwt: String, now: Date) -> Date? {
        // NumericDate: JSONSerialization gives an NSNumber, integral or not.
        // Within a year of now at most: a far or non-finite one is malformed (and would trap as an Int64).
        guard let exp = (claims(jwt)?["exp"] as? NSNumber)?.doubleValue, exp.isFinite, exp > 0,
              exp < now.timeIntervalSince1970 + 366 * 86_400 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// The ChatGPT account id in the access token's auth claim, for an `auth.json` without `account_id`.
    static func accountClaim(_ jwt: String) -> String? {
        let all = claims(jwt)
        let auth = all?["https://api.openai.com/auth"] as? [String: Any]
        return (auth?["chatgpt_account_id"] as? String) ?? (all?["chatgpt_account_id"] as? String)
    }
}
