import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// The launch's features on the Sentry scope, as the `features_hash` and `features`
/// tags and the `features` context; names only, the tag cut to Sentry's length at an entry boundary.
@Suite struct CrashFeatureScopeTests {
    private static let features = CrashFeatureScope(hash: "363b2a8f1f789985",
                                                    nonDefault: ["hangReportsSchema3=on@env", "vsyncHub=off@remote"])

    @Test func theTagsNameTheHashAndEveryOverride() {
        #expect(Self.features.tags == ["features_hash": "363b2a8f1f789985",
                                       "features": "hangReportsSchema3=on@env,vsyncHub=off@remote"])
        #expect(CrashFeatureScope(hash: "0123456789abcdef", nonDefault: []).tags["features"] == CrashFeatureScope.noOverrides)
    }

    @Test func theScopeCarriesTheTagsAndTheFullListInItsContext() throws {
        let scope = Scope()
        Self.features.apply(to: scope)
        let serialized = scope.serialize()
        #expect(serialized["tags"] as? [String: String] == Self.features.tags)
        let contexts = try #require(serialized["context"] as? [String: Any])
        let context = try #require(contexts["features"] as? [String: Any])
        #expect(context["hash"] as? String == "363b2a8f1f789985")
        #expect(context["non_default"] as? [String] == Self.features.nonDefault)
    }

    @Test func aLongListKeepsWholeEntriesAndCountsTheRest() {
        let entries = (0 ..< 40).map { "feature\($0)=on@remote" }
        let tag = CrashFeatureScope.joined(entries, limit: CrashFeatureScope.maxTagLength)
        #expect(tag.count <= CrashFeatureScope.maxTagLength)
        let parts = tag.split(separator: ",").map(String.init)
        let kept = parts.dropLast()
        #expect(Array(kept) == Array(entries.prefix(kept.count)))
        #expect(parts.last == "+\(entries.count - kept.count)")
        #expect(CrashFeatureScope.joined([String(repeating: "a", count: 300)], limit: 200) == "+1")
    }

    @Test func settingTheFeaturesDoesNothingWhileSentryIsOff() {
        let off = CrashReporter(policy: CrashReportingPolicy(
            bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
            telemetryOptIn: false, managedDisablesTelemetry: false, processEnvironment: [:]))
        off.setFeatures(Self.features)
        #expect(!off.isStarted)
    }
}
