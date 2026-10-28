#if DEBUG || CMUX_BENCH_HOOKS
/// The `settings` facet (schemas/oracle/snapshot-v1.schema.json): the sha256 of the
/// applied effective config, the settings set to a value other than their default, and the motion arm read
/// back. The host reads them in the snapshot's main-actor turn from the settings it already applied
/// (`CmuxConfigSnapshot.oracleDigest`), so the turn opens no file; this type only gives them the schema's shape.
public struct OracleSettingsFacet: OracleFacetProvider {
    /// One reading of the applied settings.
    public struct Reading: Sendable, Hashable {
        /// `sha256:<hex>` of the effective document as canonical JSON.
        public var effectiveSha256: String
        /// Dotted keys, sorted.
        public var nonDefaultKeys: [String]
        /// The motion gates' master switch: `ui.animations.enabled`, off under `ui.calm` "still".
        public var motionEnabled: Bool
        /// `ui.animationSpeed` as the gates apply it, as its time scale (fast 1, normal 1.5, off 0).
        public var motionSpeed: Double
        /// Reduce Motion as the motion gates see it.
        public var reduceMotion: Bool

        public init(effectiveSha256: String, nonDefaultKeys: [String], motionEnabled: Bool, motionSpeed: Double, reduceMotion: Bool) {
            self.effectiveSha256 = effectiveSha256
            self.nonDefaultKeys = nonDefaultKeys
            self.motionEnabled = motionEnabled
            self.motionSpeed = motionSpeed
            self.reduceMotion = reduceMotion
        }

        /// The facet's object.
        public var value: OracleValue {
            [
                "effectiveSha256": .string(effectiveSha256),
                "nonDefaultKeys": .array(nonDefaultKeys.map(OracleValue.string)),
                "motion": ["enabled": .bool(motionEnabled), "speed": .number(motionSpeed), "reduceMotion": .bool(reduceMotion)],
            ]
        }
    }

    public var facet: OracleFacet { .settings }
    public let capture: OracleFacetCapture

    /// - Parameter read: The applied settings now; nil when this process has no settings controller, which
    ///   answers not-comparable.
    public init(read: @escaping @MainActor @Sendable () -> Reading?) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = read() else {
                return .notComparable(reason: "no settings controller in this process", task: OracleFacet.settings.task)
            }
            return reading.value
        }
    }
}
#endif
