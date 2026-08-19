import Foundation

/// Resolves MDM-managed ("forced") preference values for cmux's enterprise
/// policy keys.
///
/// macOS delivers configuration-profile payloads as *forced* preference
/// values: `UserDefaults` returns them for reads, `objectIsForced(forKey:)`
/// reports them, and user-level writes can never override them. This type is
/// the single place cmux asks two questions:
///
/// - Is a ``ManagedDevicePolicyKey`` enforced by a profile right now?
/// - Is an arbitrary `UserDefaults` key forced, so a writer (the `cmux.json`
///   importer, Settings UI, CLI) must not fight it?
///
/// Channel builds (debug, nightly, staging) run under their own bundle
/// identifiers, so a profile targeting the release payload domain
/// ``releasePayloadDomain`` would not reach them through their own domain.
/// To let one profile govern every channel, the resolver also consults the
/// release domain when the app's own domain does not force the key.
///
/// ```swift
/// let policy = ManagedDevicePolicy()
/// if policy.isEnforced(.disableEmbeddedBrowser) { /* refuse to create a pane */ }
/// ```
public struct ManagedDevicePolicy: Sendable {
    /// The preference domain administrators target with a configuration
    /// profile: the release app's bundle identifier.
    public static let releasePayloadDomain = "com.cmuxterm.app"

    /// Posted (on the default `NotificationCenter`) by the app's policy
    /// enforcement whenever the enforced state of any
    /// ``ManagedDevicePolicyKey`` changes at runtime. UI that renders managed
    /// state observes this to re-read the resolver promptly.
    public static let didChangeNotification = Notification.Name("cmux.managedDevicePolicyDidChange")

    /// Returns the profile-forced object stored for `key` in `defaults`, or
    /// `nil` when no profile forces the key. The default probe uses
    /// `UserDefaults.objectIsForced(forKey:)`; tests inject their own probe
    /// because forced values cannot be simulated without installing a real
    /// profile.
    public typealias ForcedObjectProbe = @Sendable (_ defaults: UserDefaults, _ key: String) -> Any?

    // nonisolated(unsafe): UserDefaults is documented thread-safe but the SDK
    // does not mark it Sendable; these are immutable handles, never mutated.
    nonisolated(unsafe) private let defaults: UserDefaults
    nonisolated(unsafe) private let releaseDomainDefaults: UserDefaults?
    private let forcedObject: ForcedObjectProbe

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - defaults: The app's own preference domain. Defaults to
    ///     `UserDefaults.standard`.
    ///   - releaseDomainDefaults: A fallback domain consulted when the app's
    ///     own domain does not force a key. Defaults to the release payload
    ///     domain for channel builds and `nil` for the release build itself
    ///     (whose own domain *is* the payload domain). Pass `nil` to disable
    ///     the fallback.
    ///   - forcedObject: Probe answering whether a profile forces a key in a
    ///     given domain. Tests inject a deterministic probe.
    public init(
        defaults: UserDefaults = .standard,
        releaseDomainDefaults: UserDefaults? = ManagedDevicePolicy.defaultReleaseDomainDefaults(),
        forcedObject: @escaping ForcedObjectProbe = { defaults, key in
            defaults.objectIsForced(forKey: key) ? defaults.object(forKey: key) : nil
        }
    ) {
        self.defaults = defaults
        self.releaseDomainDefaults = releaseDomainDefaults
        self.forcedObject = forcedObject
    }

    /// The release-domain fallback suite for the running process, or `nil`
    /// when the process already runs under the release bundle identifier
    /// (its own domain is the payload domain, so no fallback is needed).
    ///
    /// - Parameter bundleIdentifier: The running app's bundle identifier.
    ///   Defaults to `Bundle.main.bundleIdentifier`.
    public static func defaultReleaseDomainDefaults(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults? {
        guard bundleIdentifier != releasePayloadDomain else { return nil }
        return UserDefaults(suiteName: releasePayloadDomain)
    }

    /// Whether a configuration profile currently enforces `key` (forces it
    /// to `true`) in the app's own domain or the release fallback domain.
    ///
    /// A profile forcing the key to `false` — or to a non-Boolean value —
    /// does not enforce the policy.
    public func isEnforced(_ key: ManagedDevicePolicyKey) -> Bool {
        forcedBool(for: key) == true
    }

    /// The profile-forced Boolean for `key`, or `nil` when no profile forces
    /// it (or forces a non-Boolean value).
    public func forcedBool(for key: ManagedDevicePolicyKey) -> Bool? {
        forcedBool(forUserDefaultsKey: key.rawValue)
    }

    /// The profile-forced Boolean stored under `userDefaultsKey`, checking
    /// the app's own domain first and then the release fallback domain.
    public func forcedBool(forUserDefaultsKey userDefaultsKey: String) -> Bool? {
        if let value = forcedObject(defaults, userDefaultsKey) {
            return value as? Bool
        }
        if let releaseDomainDefaults,
           let value = forcedObject(releaseDomainDefaults, userDefaultsKey) {
            return value as? Bool
        }
        return nil
    }

    /// A stream that yields once per ``didChangeNotification`` post. Elements
    /// are `Void`, so SwiftUI `.task` loops can iterate it under strict
    /// concurrency; the underlying observer is removed when the stream's
    /// consumer cancels.
    ///
    /// ```swift
    /// .task {
    ///     for await _ in ManagedDevicePolicy.changeSignals() {
    ///         managed = ManagedDevicePolicy().isEnforced(.disableEmbeddedBrowser)
    ///     }
    /// }
    /// ```
    public static func changeSignals(
        notificationCenter: NotificationCenter = .default
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = NotificationObserverToken(
                notificationCenter.addObserver(
                    forName: didChangeNotification,
                    object: nil,
                    queue: nil
                ) { _ in continuation.yield(()) },
                notificationCenter: notificationCenter
            )
            continuation.onTermination = { _ in token.remove() }
        }
    }

    /// Whether the embedded-browser disable is management-locked: the
    /// dedicated ``ManagedDevicePolicyKey/disableEmbeddedBrowser`` policy is
    /// enforced, or the user-level browser-disabled key itself is forced to
    /// `true` by a profile. Every entrypoint (runtime gate, Settings badge,
    /// palette, CLI) composes the check through this single definition.
    ///
    /// - Parameter browserDisabledUserDefaultsKey: The user-level key
    ///   (`browserDisabledOverride`) from the settings catalog.
    public func isBrowserDisableLocked(browserDisabledUserDefaultsKey: String) -> Bool {
        if isEnforced(.disableEmbeddedBrowser) {
            return true
        }
        return forcedBool(forUserDefaultsKey: browserDisabledUserDefaultsKey) == true
    }

    /// Whether a profile forces `userDefaultsKey` in the app's *own* domain.
    ///
    /// This is the write-suppression check: stores that write to
    /// `UserDefaults.standard` (the `cmux.json` importer, settings reset)
    /// must skip forced keys, because writing under a forced value is at
    /// best a no-op and at worst a write loop. The release fallback domain
    /// is not consulted — it never conflicts with writes to the app's own
    /// domain.
    public func isKeyForcedInAppDomain(_ userDefaultsKey: String) -> Bool {
        forcedObject(defaults, userDefaultsKey) != nil
    }
}
