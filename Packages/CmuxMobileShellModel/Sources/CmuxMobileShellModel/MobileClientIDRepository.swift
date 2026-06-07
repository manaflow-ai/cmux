public import Foundation

/// Owns the per-install mobile client identifier, persisted in an injected
/// `UserDefaults`.
///
/// Each iOS install needs a stable UUID so the Mac can distinguish concurrent
/// viewers of the same surface (shared-grid resize, viewport pinning). The
/// identifier is created once on first read and reused for the life of the
/// install. The backing `UserDefaults` is injected so the repository is testable
/// without touching `UserDefaults.standard`; the app constructs it at the
/// composition root with `UserDefaults.standard`.
///
/// ```swift
/// let repository = MobileClientIDRepository(defaults: .standard)
/// let clientID = repository.clientID
/// ```
public struct MobileClientIDRepository: Sendable {
    /// The defaults key under which the client identifier is stored.
    public static let defaultsKey = "dev.cmux.mobile.clientID"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Create a repository backed by the given defaults store.
    /// - Parameter defaults: The persistence store for the client identifier.
    ///   Inject a suite-scoped `UserDefaults` in tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stable per-install client identifier.
    ///
    /// Returns the persisted UUID string, creating and persisting a new one on
    /// first access (or when the stored value is not a valid UUID).
    public var clientID: String {
        resolveClientID().id
    }

    /// The client identifier together with whether this read created it.
    ///
    /// The `created` flag is `true` only on the very first resolution on an
    /// install (the install/first-launch proxy). Callers that emit an
    /// `ios_app_first_launch` analytics event use this instead of having the
    /// emitter injected into this `Sendable` value type, keeping the repository a
    /// pure return-a-value type.
    ///
    /// - Returns: A tuple of the stable `id` and whether it was just `created`.
    public func resolveClientID() -> (id: String, created: Bool) {
        if let existing = defaults.string(forKey: Self.defaultsKey),
           UUID(uuidString: existing) != nil {
            return (existing, false)
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: Self.defaultsKey)
        return (created, true)
    }
}
