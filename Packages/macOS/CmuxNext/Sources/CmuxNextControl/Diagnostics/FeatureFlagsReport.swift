public import CmuxNextFeatures
public import CmuxNextSettings

/// `features.list`: every feature of the launch's ``FeatureList`` in registry
/// order with its value and the input that decided it, as chrome://flags
/// lists each flag with its state (components/flags_ui/flags_state.cc) and
/// chrome://version the active variations
/// (chrome/browser/ui/webui/version/version_ui.cc). `cmux settings
/// feature-flags [--json]` reads it.
///
/// Read-only and parameterless: the list is immutable after launch, so the
/// method answers off the main actor from the last published snapshot, and
/// any param a caller sends is ignored (nothing it names can change or run).
/// The App registers ``method`` with its ``FeatureList``.
public struct FeatureFlagsReport: Sendable {
    public static let methodName = "features.list"

    public let features: FeatureList

    public init(features: FeatureList) {
        self.features = features
    }

    public var method: ControlMethod {
        let report = self
        return ControlMethod.snapshot(Self.methodName) { _ in report.json }.readingLastPublished()
    }

    /// `{channel, local_overrides, unknown_names, features: [...]}`. A
    /// feature's `source` is ``Feature/Source``'s wire name (`policy`, `env`,
    /// `local`, `remote`, `trial`, `default`) and `default` its channel
    /// default, so a reader sees what an override changed. `local_overrides`
    /// is whether Labs and Debug toggles apply on this channel (DEV and
    /// NIGHTLY only).
    public var json: JSONValue {
        let channel = features.channel
        return .object([
            "channel": .string(channel.rawValue),
            "local_overrides": .bool(channel.allowsLocalOverrides),
            "unknown_names": .array(features.unknownNames.map(JSONValue.string)),
            "features": .array(features.entries.map { Self.row($0.feature, $0.resolution, channel: channel) }),
        ])
    }

    static func row(_ feature: Feature, _ resolution: Feature.Resolution, channel: Feature.Channel) -> JSONValue {
        .object([
            "name": .string(feature.name),
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
}
