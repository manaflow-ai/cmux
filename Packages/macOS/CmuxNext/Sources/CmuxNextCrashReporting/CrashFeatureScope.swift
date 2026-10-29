public import CmuxNextFeatures
public import CmuxNextWakeups
public import Sentry

/// This launch's features on the Sentry scope: the `features_hash` tag (the hash
/// of every feature's value, `CmuxNextFeatures`' `FeatureFieldState`), the `features` tag (the overrides as
/// `name=on@remote`, comma-separated, cut to Sentry's tag length) and the full list in the `features`
/// context. Chrome puts the active variations into crash keys the same way
/// (components/variations/variations_crash_keys.cc).
///
/// Scope, not `beforeSend`: a crash is sent at the next launch, and the scope saved with it at crash
/// time names the features that crashed, where `beforeSend` would name the next launch's.
public nonisolated struct CrashFeatureScope: Sendable, Equatable {
    /// Sentry's longest tag value.
    public static let maxTagLength = 200
    /// The `features` tag when no override decided a feature.
    public static let noOverrides = "none"

    /// 16 lowercase hex digits.
    public let hash: String
    /// The features an override decided, each `name=on|off@source`, sorted by name.
    public let nonDefault: [String]

    public init(hash: String, nonDefault: [String]) {
        self.hash = hash
        self.nonDefault = nonDefault
    }

    /// A launch's ``FeatureFieldState`` as Sentry scope tags.
    public init(_ state: FeatureFieldState) {
        self.init(hash: state.hash, nonDefault: state.nonDefault.map(\.description))
    }

    /// `features_hash` and `features`.
    public var tags: [String: String] {
        ["features_hash": hash, "features": Self.joined(nonDefault, limit: Self.maxTagLength)]
    }

    /// The `features` context: the hash and every override.
    public var context: [String: Any] { ["hash": hash, "non_default": nonDefault] }

    /// Sets ``tags`` and ``context`` on `scope`.
    public func apply(to scope: Scope) {
        for (key, value) in tags { scope.setTag(value: value, key: key) }
        scope.setContext(value: context, key: "features")
    }

    /// `entries` joined by commas, in at most `limit` characters: whole entries from the first, then
    /// `+N` for the `N` left out; ``noOverrides`` when there are none.
    static func joined(_ entries: [String], limit: Int) -> String {
        guard !entries.isEmpty else { return noOverrides }
        var kept = entries[...]
        while !kept.isEmpty {
            let left = entries.count - kept.count
            let text = (Array(kept) + (left > 0 ? ["+\(left)"] : [])).joined(separator: ",")
            if text.count <= limit { return text }
            kept = kept.dropLast()
        }
        return "+\(entries.count)"
    }
}

extension CrashReporter {
    /// Puts `features` on the scope every later event and crash carries, replacing the last ones: right after
    /// ``start(profile:)``, then at each change of the features the app runs with. Does nothing while Sentry is off.
    public func setFeatures(_ features: CrashFeatureScope) {
        guard isStarted else { return }
        SentrySDK.configureScope { scope in features.apply(to: scope) }
    }

    /// Sets ``setFeatures(_:)`` from `read` now and again each time its value changes, so a crash carries the
    /// features it ran with after a live toggle changed one, as Chrome updates its variations crash keys when a
    /// field trial's group changes (components/variations/variations_crash_keys.cc). `background`: nothing on
    /// screen changes. The caller holds the returned observation for the process's life.
    @MainActor
    public func followFeatures(on work: MainWorkScheduler, _ read: @escaping @MainActor () -> CrashFeatureScope)
        -> ServiceObservation<CrashFeatureScope> {
        ServiceObservation(.background, owner: "CrashReporter.features", on: work, read: read) { [self] in setFeatures($0) }
    }
}
