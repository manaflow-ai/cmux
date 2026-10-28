public import CmuxNextDaemon
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
///
/// The daemon outlives the app: ``daemon`` holds the local daemon's answer to the
/// app's last hello. A `daemon` or `both` row the daemon runs with another value says so (`daemon: pending`
/// with `daemon_enabled`, until the daemon restarts); a kill switch the hello turned off there says
/// `daemon: applied`.
public struct FeatureFlagsReport: Sendable {
    public static let methodName = "features.list"
    /// The settings JSON the socket answers with; CmuxNextDaemon (for the hello's report) has its own `JSONValue`.
    public typealias JSONValue = CmuxNextSettings.JSONValue
    /// A Debug toggle's value for a feature, read with the report: nil while it is unset or does not apply.
    public typealias LiveLocalOverride = @Sendable () -> Bool?

    public let features: FeatureList
    /// This launch's safe mode (``FeatureSafeMode/state``), nil where the App applies no remote document.
    public let safeMode: FeatureSafeMode.State?
    /// The Debug toggles that override a feature after the launch resolved it (step 3 of ``FeatureList``'s
    /// order), by feature name. Each answers nil where policy or the environment decided the feature, and in Release.
    public let liveLocal: [String: LiveLocalOverride]
    /// The app's daemon features and the local daemon's last answer to them; nil where the App has no local daemon.
    public let daemon: DaemonFeatureHello?

    public init(features: FeatureList, safeMode: FeatureSafeMode.State? = nil, liveLocal: [String: LiveLocalOverride] = [:],
                daemon: DaemonFeatureHello? = nil) {
        self.features = features
        self.safeMode = safeMode
        self.liveLocal = liveLocal
        self.daemon = daemon
    }

    /// The value the app runs with for `feature`: for a `both` feature the local daemon kept another value of, the
    /// daemon's (``daemonSessionValue(of:)``, under the launch's source); else its live Debug toggle (source
    /// `local`) when one is set; else the launch's resolution. Every reader of the report (rows, hashes, field
    /// reports) so names the value the app runs with.
    public func resolution(of feature: Feature) -> Feature.Resolution {
        let launch = features.resolution(of: feature)
        if let session = daemonSessionValue(of: feature) { return Feature.Resolution(isEnabled: session, source: launch.source) }
        if let value = liveLocal[feature.name]?() { return Feature.Resolution(isEnabled: value, source: .local) }
        return launch
    }

    /// The daemon's value of a `both` feature the app runs with this session instead of its launch value
    /// (``DaemonFeatureHello/sessionValues``); nil when they are equal, not settled yet, or not a `both` feature.
    public func daemonSessionValue(of feature: Feature) -> Bool? {
        guard feature.process == .both, let session = daemon?.sessionValues?[feature.name],
              session != features.resolution(of: feature).isEnabled else { return nil }
        return session
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

    /// `{channel, local_overrides, safe_mode, unknown_names, daemon, features_hash, features: [...]}`. `features_hash`
    /// is ``fieldState``'s hash of the values below, the arm hang reports and Sentry name (a perf-lab result's
    /// `features_hash`).
    /// A feature's `state` is `on` or `off` (`enabled` the same as a bool),
    /// `source` is ``Feature/Source``'s wire name (`policy`, `env`, `local`,
    /// `remote`, `trial`, `default`) and `default` its channel default, so a
    /// reader sees what an override changed. `local_overrides` is whether
    /// Labs and Debug toggles apply on this channel (DEV and NIGHTLY only). `daemon` is the local daemon's
    /// answer to the last hello (`{hash, applied, pending}`), null before one or from an older daemon.
    /// A `both` feature the app runs with the daemon's value this session (``daemonSessionValue(of:)``) shows
    /// that value, source `daemon`, and `app_enabled`, the app's own launch value.
    public var json: JSONValue {
        let channel = features.channel
        let reply = daemon?.lastReply
        let entries = self.entries
        let rows: [JSONValue] = entries.map { entry in
            Self.row(entry.feature, entry.resolution, channel: channel, daemon: reply,
                     fromDaemon: daemonSessionValue(of: entry.feature) != nil)
        }
        let daemonJSON: JSONValue = reply.map(Self.daemonJSON) ?? .null
        let safeModeJSON: JSONValue = safeMode.map(Self.safeModeJSON) ?? .null
        return .object([
            "channel": .string(channel.rawValue),
            "local_overrides": .bool(channel.allowsLocalOverrides),
            "safe_mode": safeModeJSON,
            "unknown_names": .array(features.unknownNames.map(JSONValue.string)),
            "daemon": daemonJSON,
            "features_hash": .string(FeatureFieldState(entries).hash),
            "features": .array(rows),
        ])
    }

    /// The Labs page's card: ``json`` plus `next_local`, the local choices the
    /// next launch applies (``FeatureLocalOverrideStore/next``), by name.
    public func labsJSON(nextLocal: FeatureLocalOverrides) -> JSONValue {
        guard case .object(var object) = json else { return json }
        object["next_local"] = .object(nextLocal.values.mapValues(JSONValue.bool))
        return .object(object)
    }

    static func row(_ feature: Feature, _ resolution: Feature.Resolution, channel: Feature.Channel,
                    daemon: ClientHelloRequest.FeatureReport?, fromDaemon: Bool) -> JSONValue {
        guard case .object(var row) = row(feature, resolution, channel: channel) else { return .null }
        if fromDaemon {
            row["source"] = .string("daemon")
            row["app_enabled"] = .bool(!resolution.isEnabled)
        }
        if let pending = daemon?.pending.first(where: { $0.name == feature.name }) {
            row["daemon"] = .string("pending")
            row["daemon_enabled"] = .bool(pending.daemon)
        } else if daemon?.applied.contains(feature.name) == true {
            row["daemon"] = .string("applied")
            row["daemon_enabled"] = .bool(false)
        }
        return .object(row)
    }

    static func daemonJSON(_ report: ClientHelloRequest.FeatureReport) -> JSONValue {
        .object([
            "hash": .string(report.hash),
            "applied": .array(report.applied.map(JSONValue.string)),
            "pending": .array(report.pending.map {
                .object(["name": .string($0.name), "app": .bool($0.app), "daemon": .bool($0.daemon)])
            }),
        ])
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
