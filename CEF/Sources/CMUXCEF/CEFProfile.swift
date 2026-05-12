import Foundation
import CMUXCEFBridge

/// A cmux-named CEF profile, backed by one `CefRequestContext` and one
/// on-disk cache directory.
@MainActor
public final class CEFProfile {

    /// The cmux-side name (e.g. "default", "work", "isolated-<uuid>").
    /// Must be non-empty. Names are normalized to a path-safe form by the
    /// bridge; collisions on the normalized form are not detected.
    public let name: String

    /// Absolute path to the on-disk cache directory used by this profile.
    public let cachePath: URL

    /// True for profiles whose name begins with `"isolated-"`. These are
    /// torn down (cache dir removed) when their last referencing pane closes.
    public var isEphemeral: Bool { name.hasPrefix("isolated-") }

    fileprivate let bridge: CMUXCEFProfileBridge

    fileprivate init(bridge: CMUXCEFProfileBridge) {
        self.name = bridge.name
        self.cachePath = URL(fileURLWithPath: bridge.cachePath)
        self.bridge = bridge
    }
}

/// Process-wide profile registry. Same name returns the same `CEFProfile`
/// instance for the lifetime of the cmux process.
@MainActor
public final class CEFProfileRegistry {

    public static let shared = CEFProfileRegistry()

    private let bridge = CMUXCEFProfileRegistryBridge.shared()
    private var byName: [String: CEFProfile] = [:]

    private init() {}

    /// Acquire the profile bridge for `name`, creating it (and its cache
    /// directory) on first call.
    public func profile(named name: String) -> CEFProfile {
        precondition(!name.isEmpty, "profile name must be non-empty")
        if let cached = byName[name] {
            return cached
        }
        let bridge = self.bridge.profile(forName: name)
        let profile = CEFProfile(bridge: bridge)
        byName[name] = profile
        return profile
    }

    /// Release the profile. For ephemeral profiles the cache directory is
    /// scheduled for removal a short time after the underlying
    /// `CefRequestContext` is destroyed. Named profiles keep their cache
    /// directory on disk.
    public func release(name: String) {
        byName.removeValue(forKey: name)
        bridge.destroyProfile(forName: name)
    }
}

extension CEFProfile {
    /// Internal access used by `CEFBrowser`.
    var underlyingBridge: CMUXCEFProfileBridge { bridge }
}
