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

/// Persists website-notification decisions by browser profile and exact WebKit
/// security origin. Display aliases are never used as steady-state keys.
///
/// Origins are canonicalized to lowercased HTTP(S) origins without paths. The
/// repository is deliberately independent of WebKit so both the native provider
/// and compatibility shim share one permission source of truth. It is main-actor
/// isolated because WebKit permission delegates require synchronous replies.
@MainActor
public final class BrowserNotificationPermissionRepository {
    private typealias PermissionMap = [String: [String: BrowserNotificationPermissionDecision]]

    /// `UserDefaults` key for the encoded permission map.
    public static let defaultsKey = "browser.notificationPermissions.v1"

    private let defaults: UserDefaults
    /// Decoded state paired with the exact persisted bytes. A changed snapshot
    /// invalidates the cache, including writes made through another repository.
    private var decodeCache: (data: Data?, map: PermissionMap)?

    /// Creates a repository backed by `defaults`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the stored decision for a profile and origin.
    public func decision(for origin: URL, profileID: UUID) -> BrowserNotificationPermissionDecision {
        guard let origin = Self.canonicalOrigin(origin) else { return .denied }
        return loadMap()[profileID.uuidString]?[origin] ?? .prompt
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

    /// Returns the allowed and denied origin sets for a profile in one load.
    public func origins(for profileID: UUID) -> (allowed: Set<String>, denied: Set<String>) {
        var allowed = Set<String>()
        var denied = Set<String>()
        for (origin, decision) in loadMap()[profileID.uuidString] ?? [:] {
            switch decision {
            case .allowed: allowed.insert(origin)
            case .denied: denied.insert(origin)
            case .prompt: break
            }
        }
        return (allowed, denied)
    }

    /// Returns all allowed origins for a profile.
    public func allowedOrigins(for profileID: UUID) -> Set<String> {
        origins(for: profileID).allowed
    }

    /// Returns all denied origins for a profile.
    public func deniedOrigins(for profileID: UUID) -> Set<String> {
        origins(for: profileID).denied
    }

    /// Moves an older decision to the exact current security origin when the
    /// destination has no decision yet, then returns the destination decision.
    @discardableResult
    public func migrateDecisionIfNeeded(
        from legacyOrigin: URL,
        to securityOrigin: URL,
        profileID: UUID
    ) -> BrowserNotificationPermissionDecision {
        guard let legacyKey = Self.canonicalOrigin(legacyOrigin),
              let securityKey = Self.canonicalOrigin(securityOrigin) else {
            return .denied
        }
        guard legacyKey != securityKey else {
            return decision(for: securityOrigin, profileID: profileID)
        }

        var result = BrowserNotificationPermissionDecision.prompt
        mutateMap { map in
            var profile = map[profileID.uuidString] ?? [:]
            if let existing = profile[securityKey] {
                result = existing
                return
            }
            guard let legacy = profile.removeValue(forKey: legacyKey) else { return }
            profile[securityKey] = legacy
            map[profileID.uuidString] = profile
            result = legacy
        }
        return result
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
        if host.contains(":") {
            components.percentEncodedHost = "[\(host)]"
        } else {
            components.host = host
        }
        components.port = url.port
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func mutateMap(_ body: (inout PermissionMap) -> Void) {
        let original = loadMap()
        var map = original
        body(&map)
        guard map != original else { return }
        if map.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            decodeCache = (data: nil, map: [:])
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.defaultsKey)
            decodeCache = (data: data, map: map)
        }
    }

    private func loadMap() -> PermissionMap {
        let data = defaults.data(forKey: Self.defaultsKey)
        if let decodeCache, decodeCache.data == data {
            return decodeCache.map
        }

        let map = data.flatMap { try? JSONDecoder().decode(PermissionMap.self, from: $0) } ?? [:]
        decodeCache = (data: data, map: map)
        return map
    }
}
