#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The settings facet: the applied config's hash, its non-default keys and the motion arm in the
/// schema's shape, read in the snapshot's main-actor turn; with no settings controller it is not-comparable with
/// its task, never an empty pass. Run: `swift test --filter OracleSettingsFacetTests`.
@MainActor
struct OracleSettingsFacetTests {
    @Test func aReadingIsTheSchemasObject() throws {
        let facet = OracleSettingsFacet {
            OracleSettingsFacet.Reading(effectiveSha256: "sha256:" + String(repeating: "0", count: 64),
                                        nonDefaultKeys: ["ui.animations.enabled"], motionEnabled: false, motionSpeed: 1.5,
                                        reduceMotion: true)
        }
        #expect(facet.facet == .settings)
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.settings]).completed)
        #expect(snapshot["settings"] == [
            "effectiveSha256": .string("sha256:" + String(repeating: "0", count: 64)),
            "nonDefaultKeys": ["ui.animations.enabled"],
            "motion": ["enabled": false, "speed": 1.5, "reduceMotion": true],
        ])
    }

    @Test func noSettingsControllerIsNotComparable() throws {
        let snapshot = try #require(try OracleFacets([OracleSettingsFacet { nil }]).beginCapture([.settings]).completed)
        #expect(snapshot["settings"]?["status"] == "not-comparable")
        #expect(snapshot["settings"]?["task"] == "p15-oracle-039")
    }
}
#endif
