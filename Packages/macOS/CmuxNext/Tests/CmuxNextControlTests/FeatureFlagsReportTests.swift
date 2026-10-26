@testable import CmuxNextControl
import CmuxNextFeatures
import CmuxNextSettings
import Testing

/// `features.list` (p12-perf-process-096): every feature with its state and
/// source, read-only, answered with no params and unchanged by any.
/// Run: `swift test --filter FeatureFlagsReportTests`.
struct FeatureFlagsReportTests {
    private static func feature(_ index: Int, _ name: String, _ defaults: FeatureDefaults, _ kind: Feature.Kind) -> Feature {
        Feature(index: index, name: name, owner: "PL-test", description: "A test feature.", kind: kind, process: .app,
                chromiumFeature: nil, defaults: defaults, expires: kind == .perfPath ? "2026-12-01" : nil, params: [],
                stories: [], sticky: kind == .killSwitch, runtimeMutable: false)
    }

    private static let registry = FeatureRegistry([
        feature(0, "perfThing", FeatureDefaults(dev: true, nightly: false, release: false), .perfPath),
        feature(1, "killThing", FeatureDefaults(all: true), .killSwitch),
        feature(2, "labsThing", FeatureDefaults(all: false), .labs),
    ])

    private static func list(_ channel: Feature.Channel) -> FeatureList {
        let overrides = FeatureOverrides(policyDisabled: ["killThing"],
                                         environment: [FeatureOverrides.enableVariable: "labsThing,noSuchThing"],
                                         remote: ["perfThing": true])
        return FeatureList(registry: registry, channel: channel, overrides: overrides)
    }

    private static func router(_ list: FeatureList) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.register([FeatureFlagsReport(features: list).method])
        return router
    }

    @Test func eachFeatureReportsItsStateAndSource() throws {
        let report = FeatureFlagsReport(features: Self.list(.nightly)).json
        #expect(report["channel"] == .string("nightly"))
        #expect(report["unknown_names"] == .array([.string("noSuchThing")]))
        let rows = try #require(report["features"]?.arrayValue)
        #expect(rows.map { $0["name"]?.stringValue } == ["perfThing", "killThing", "labsThing"])
        #expect(rows.map { $0["source"]?.stringValue } == ["remote", "policy", "env"])
        #expect(rows.map { $0["enabled"]?.boolValue } == [true, false, true])
        #expect(rows.map { $0["default"]?.boolValue } == [false, true, false])
        #expect(rows[0]["expires"] == .string("2026-12-01"))
        #expect(rows[1]["expires"] == .null)
        #expect(rows[1]["sticky"] == .bool(true))
        #expect(rows[2]["kind"] == .string("labs"))
    }

    @Test func localTogglesApplyOnlyOnDevAndNightly() {
        #expect(FeatureFlagsReport(features: Self.list(.dev)).json["local_overrides"] == .bool(true))
        #expect(FeatureFlagsReport(features: Self.list(.nightly)).json["local_overrides"] == .bool(true))
        #expect(FeatureFlagsReport(features: Self.list(.release)).json["local_overrides"] == .bool(false))
    }

    @Test func theMethodIsAReadOnlySnapshotRead() throws {
        let method = try #require(Self.router(Self.list(.release)).method(named: FeatureFlagsReport.methodName))
        #expect(method.lane == .snapshot)
        #expect(method.readsLastPublished)
    }

    /// A caller's params name nothing the method runs or changes: the answer is the same.
    @Test func paramsChangeNothing() async throws {
        let list = Self.list(.dev)
        let router = Self.router(list)
        let plain = try await router.handle(ControlRequest(id: "1", method: FeatureFlagsReport.methodName, params: [:])).get()
        let loaded = try await router.handle(ControlRequest(id: "2", method: FeatureFlagsReport.methodName, params: [
            "command": .string("rm -rf ~"), "name": .string("labsThing"), "enabled": .bool(false),
        ])).get()
        #expect(plain == FeatureFlagsReport(features: list).json)
        #expect(loaded == plain)
        #expect(list.isEnabled(Self.registry.features[2]))
    }
}
