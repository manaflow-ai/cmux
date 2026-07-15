public import Foundation

/// Persists device-local viewed state keyed by workspace, path, and patch digest.
public struct DiffViewedStore: Sendable {
    /// The defaults entry containing the viewed-key map.
    public static let defaultsKey = "dev.cmux.mobile.diff.viewed.v1"

    // UserDefaults is Apple-documented thread-safe; the dependency is injected.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a viewed store over an injected defaults suite.
    /// - Parameter defaults: The persistence suite; tests should inject an isolated suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns whether this exact patch revision is marked viewed.
    /// - Parameters:
    ///   - workspaceID: Stable workspace identity.
    ///   - path: Repository-relative file path.
    ///   - patchDigest: Content digest supplied by the diff service.
    /// - Returns: `true` only for an exact workspace, path, and digest match.
    public func isViewed(workspaceID: String, path: String, patchDigest: String) -> Bool {
        viewedKeys().contains(key(workspaceID: workspaceID, path: path, patchDigest: patchDigest))
    }

    /// Updates viewed state for this exact patch revision.
    /// - Parameters:
    ///   - viewed: The new viewed state.
    ///   - workspaceID: Stable workspace identity.
    ///   - path: Repository-relative file path.
    ///   - patchDigest: Content digest supplied by the diff service.
    public func setViewed(
        _ viewed: Bool,
        workspaceID: String,
        path: String,
        patchDigest: String
    ) {
        var keys = viewedKeys()
        let storageKey = key(workspaceID: workspaceID, path: path, patchDigest: patchDigest)
        if viewed {
            keys.insert(storageKey)
        } else {
            keys.remove(storageKey)
        }
        if let data = try? JSONEncoder().encode(keys) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func key(workspaceID: String, path: String, patchDigest: String) -> String {
        [workspaceID, path, patchDigest]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private func viewedKeys() -> Set<String> {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return keys
    }
}
