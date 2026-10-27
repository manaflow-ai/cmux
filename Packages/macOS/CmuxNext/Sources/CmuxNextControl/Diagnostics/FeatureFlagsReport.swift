public import CmuxNextFeatures
public import CmuxNextSettings

/// `features.list`: every feature of the launch's ``FeatureList`` in registry
/// order with its value and the input that decided it, as chrome://flags
/// lists each flag with its state (components/flags_ui/flags_state.cc) and
/// chrome://version the active variations
/// (chrome/browser/ui/webui/version/version_ui.cc). `cmux settings
/// feature-flags [--json]` and the Labs page's Feature Flags card read it.
///
/// Read-only and parameterless: the method answers off the main actor from
/// the last published snapshot, and any param a caller sends is ignored
/// (nothing it names can change or run). The App registers ``method`` with
/// its ``FeatureList`` and the Debug toggles that still override a feature
/// after launch (``liveLocal``), so each row is the value the app runs with.
public struct FeatureFlagsReport: Sendable {
    public static let methodName = "features.list"
    /// A Debug toggle's value for a feature, read with the report: nil while it is unset or does not apply.
    public typealias LiveLocalOverride = @Sendable () -> Bool?

    public let features: FeatureList
    /// This launch's safe mode (``FeatureSafeMode/state``), nil where the App applies no remote document.
    public let safeMode: FeatureSafeMode.State?
    /// The Debug toggles that override a feature after the launch resolved it (step 3 of ``FeatureList``'s
    /// order), by feature name. Each answers nil where policy or the environment decided the feature, and in Release.
    public let liveLocal: [String: LiveLocalOverride]

    public init(features: FeatureList, safeMode: FeatureSafeMode.State? = nil, liveLocal: [String: LiveLocalOverride] = [:]) {
        self.features = features
        self.safeMode = safeMode
        self.liveLocal = liveLocal
    }

    /// The value the app runs with for `feature`: its live Debug toggle (source `local`) when one is set, else
    /// the launch's resolution.
    public func resolution(of feature: Feature) -> Feature.Resolution {
        if let value = liveLocal[feature.name]?() { return Feature.Resolution(isEnabled: value, source: .local) }
        return features.resolution(of: feature)
    }

    /// Every feature with ``resolution(of:)``, in registry order.
    public var entries: [(feature: Feature, resolution: Feature.Resolution)] {
        features.registry.features.map { (feature: $0, resolution: resolution(of: $0)) }
    }

    /// The ``FeatureFieldState`` of ``entries``: what `features_hash` hashes, and what hang reports and Sentry
    /// name (the App reads it through `FeatureFlagsPage.report`), so all three name one arm, live toggles included.
    public var fieldState: FeatureFieldState { FeatureFieldState(entries) }

    public var method: ControlMethod {
        let report = self
        return ControlMethod.snapshot(Self.methodName) { _ in report.json }.readingLastPublished()
    }

    /// `{channel, local_overrides, safe_mode, unknown_names, features_hash, features: [...]}`. `features_hash` is
    /// ``fieldState``'s hash of the values below, the arm hang reports and Sentry name (a perf-lab result's
    /// `features_hash`).
    /// A feature's `state` is `on` or `off` (`enabled` the same as a bool),
    /// `source` is ``Feature/Source``'s wire name (`policy`, `env`, `local`,
    /// `remote`, `trial`, `default`) and `default` its channel default, so a
    /// reader sees what an override changed. `local_overrides` is whether
    /// Labs and Debug toggles apply on this channel (DEV and NIGHTLY only).
    public var json: JSONValue {
        let channel = features.channel
        let entries = self.entries
        return .object([
            "channel": .string(channel.rawValue),
            "local_overrides": .bool(channel.allowsLocalOverrides),
            "safe_mode": safeMode.map(Self.safeModeJSON) ?? .null,
            "unknown_names": .array(features.unknownNames.map(JSONValue.string)),
            "features_hash": .string(FeatureFieldState(entries).hash),
            "features": .array(entries.map { Self.row($0.feature, $0.resolution, channel: channel) }),
        ])
    }

    /// The Labs page's card: ``json`` plus `next_local`, the local choices the
    /// next launch applies (``FeatureLocalOverrideStore/next``), by name.
    public func labsJSON(nextLocal: FeatureLocalOverrides) -> JSONValue {
        guard case .object(var object) = json else { return json }
        object["next_local"] = .object(nextLocal.values.mapValues(JSONValue.bool))
        return .object(object)
    }

    static func row(_ feature: Feature, _ resolution: Feature.Resolution, channel: Feature.Channel) -> JSONValue {
        .object([
            "name": .string(feature.name),
            "state": .string(resolution.isEnabled ? "on" : "off"),
            "enabled": .bool(resolution.isEnabled),
            "source": .string(resolution.source.description),
            "default": .bool(feature.defaults.value(for: channel)),
            "kind": .string(feature.kind.rawValue),
            "process": .string(feature.process.rawValue),
            "owner": .string(feature.owner),
            "description": .string(feature.description),
            "expires": feature.expires.map(JSONValue.string) ?? .null,
            "sticky": .bool(feature.sticky),
            "runtime_mutable": .bool(feature.runtimeMutable),
        ])
    }

    static func safeModeJSON(_ state: FeatureSafeMode.State) -> JSONValue {
        .object([
            "level": .string(state.overridden ? "overridden" : state.level.rawValue),
            "crash_streak": .number(Double(state.streaks.crashes)),
            "fetch_failure_streak": .number(Double(state.streaks.fetchFailures)),
        ])
    }
}
