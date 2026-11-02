import CmuxNextCompat
import Foundation

/// The installs guest links' owner tokens come from (cmux#31372). A share room takes only its own
/// environment's install tokens, and the daemon names that environment's API
/// (`agent-session-share-room`, cmux-tui `platform::share_owner_api`), so there is one install per
/// API. The owner's own install and the build's default share install are given; another is made at
/// its first share in `install-share-<host>` under `root`, where a later launch finds it again, so a
/// sign-out still revokes it.
public actor ShareInstalls {
    public typealias Make = @Sendable (_ api: URL, _ folder: String) -> MacInstallIdentity

    private let root: URL
    private let fallback: MacInstallIdentity
    private let make: Make
    private let accepts: @Sendable (URL) -> Bool
    private var byOrigin: [String: MacInstallIdentity] = [:]
    private var scanned = false

    /// - Parameters:
    ///   - root: The folder the installs' stores live in.
    ///   - given: Installs that exist already, by their API (the owner's, the default share install).
    ///   - fallback: The install for a share whose API the daemon did not name (an older daemon).
    ///   - accepts: Whether an API the daemon names may get the owner's credentials
    ///     (``CloudConfiguration/acceptsShareAPI(_:)``); one it refuses gets the fallback.
    ///   - make: Makes the install for an API in a folder of `root`.
    public init(root: URL, given: [(api: URL, identity: MacInstallIdentity)], fallback: MacInstallIdentity,
                accepts: @escaping @Sendable (URL) -> Bool, make: @escaping Make) {
        self.root = root
        self.fallback = fallback
        self.accepts = accepts
        self.make = make
        for (api, identity) in given {
            guard let key = Self.origin(api), byOrigin[key] == nil else { continue }
            byOrigin[key] = identity
        }
    }

    /// The install for `api`, made at its first use; nil, a URL with no https host or one ``accepts`` refuses
    /// is the fallback.
    public func identity(for api: URL?) -> MacInstallIdentity {
        guard let api, let key = Self.origin(api), let host = api.host?.lowercased() else { return fallback }
        if let found = byOrigin[key] { return found }
        guard accepts(api) else { return fallback }
        let made = make(api, Self.folderPrefix + host)
        byOrigin[key] = made
        return made
    }

    /// Every share install but `owner` (which signs in and out on its own), with the ones an earlier
    /// launch made, so an unbind or a sign-out reaches each.
    public func all(except owner: MacInstallIdentity) -> [MacInstallIdentity] {
        if !scanned {
            scanned = true
            let names = (try? FileManager.checked.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasPrefix(Self.folderPrefix) {
                let host = String(name.dropFirst(Self.folderPrefix.count))
                if let api = URL(string: "https://\(host)"), api.host == host { _ = identity(for: api) }
            }
        }
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(owner)]
        return ([fallback] + byOrigin.values).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    static let folderPrefix = "install-share-"

    /// An https URL's origin; nil for any other scheme, so a token is never minted over plain http.
    static func origin(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return url.port.map { "https://\(host):\($0)" } ?? "https://\(host)"
    }
}
