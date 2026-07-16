public import Foundation

/// A persisted website-notification permission decision.
public enum BrowserNotificationPermissionDecision: String, Codable, Sendable {
    /// The site has not been asked yet.
    case prompt
    /// The user allowed notifications for the site.
    case allowed
    /// The user denied notifications for the site.
    case denied
}

/// Persists website-notification decisions by browser profile and logical origin.
///
/// Origins are canonicalized to lowercased HTTP(S) origins without paths. The
/// repository is deliberately independent of WebKit so both the native provider
/// and compatibility shim share one permission source of truth.
public final class BrowserNotificationPermissionRepository: @unchecked Sendable {
    /// `UserDefaults` key for the encoded permission map.
    public static let defaultsKey = "browser.notificationPermissions.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Creates a repository backed by `defaults`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the stored decision for a profile and origin.
    public func decision(for origin: URL, profileID: UUID) -> BrowserNotificationPermissionDecision {
        guard let origin = Self.canonicalOrigin(origin) else { return .denied }
        return withMap { $0[profileID.uuidString]?[origin] ?? .prompt }
    }

    /// Stores a decision for a profile and origin.
    public func setDecision(
        _ decision: BrowserNotificationPermissionDecision,
        for origin: URL,
        profileID: UUID
    ) {
        guard let origin = Self.canonicalOrigin(origin) else { return }
        mutateMap { map in
            var profile = map[profileID.uuidString] ?? [:]
            if decision == .prompt {
                profile.removeValue(forKey: origin)
            } else {
                profile[origin] = decision
            }
            map[profileID.uuidString] = profile.isEmpty ? nil : profile
        }
    }

    /// Returns all allowed origins for a profile.
    public func allowedOrigins(for profileID: UUID) -> Set<String> {
        withMap { map in
            Set((map[profileID.uuidString] ?? [:]).compactMap { key, value in
                value == .allowed ? key : nil
            })
        }
    }

    /// Returns all denied origins for a profile.
    public func deniedOrigins(for profileID: UUID) -> Set<String> {
        withMap { map in
            Set((map[profileID.uuidString] ?? [:]).compactMap { key, value in
                value == .denied ? key : nil
            })
        }
    }

    /// Removes every decision owned by a profile.
    public func clear(profileID: UUID) {
        mutateMap { $0.removeValue(forKey: profileID.uuidString) }
    }

    /// Produces the stable permission-map key for an HTTP(S) origin.
    public static func canonicalOrigin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func withMap<T>(_ body: ([String: [String: BrowserNotificationPermissionDecision]]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(loadMap())
    }

    private func mutateMap(_ body: (inout [String: [String: BrowserNotificationPermissionDecision]]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var map = loadMap()
        body(&map)
        if map.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func loadMap() -> [String: [String: BrowserNotificationPermissionDecision]] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let map = try? JSONDecoder().decode(
                  [String: [String: BrowserNotificationPermissionDecision]].self,
                  from: data
              ) else {
            return [:]
        }
        return map
    }
}
