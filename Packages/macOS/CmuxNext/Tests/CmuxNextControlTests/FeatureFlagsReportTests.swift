@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextFeatures
import Foundation
import CmuxNextSettings
import Testing

/// `features.list`: every feature with its state and
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
        #expect(report["features_hash"] == .string(Self.list(.nightly).fieldState.hash))
        let rows = try #require(report["features"]?.arrayValue)
        #expect(rows.map { $0["name"]?.stringValue } == ["perfThing", "killThing", "labsThing"])
        #expect(rows.map { $0["source"]?.stringValue } == ["remote", "policy", "env"])
        #expect(rows.map { $0["state"]?.stringValue } == ["on", "off", "on"])
        #expect(rows.map { $0["enabled"]?.boolValue } == [true, false, true])
        #expect(rows.map { $0["default"]?.boolValue } == [false, true, false])
        #expect(rows[0]["expires"] == .string("2026-12-01"))
        #expect(rows[1]["expires"] == .null)
        #expect(rows[1]["sticky"] == .bool(true))
        #expect(rows[2]["kind"] == .string("labs"))
    }

    /// The kill-switch done check (scripts/perf-lab/done_checks.py, story 13) reads `name`, `state` and `source`
    /// of each row of `cmux settings feature-flags --json`, which prints this report unchanged.
    @Test func eachRowHasTheDoneCheckFields() throws {
        let rows = try #require(FeatureFlagsReport(features: Self.list(.release)).json["features"]?.arrayValue)
        for row in rows {
            #expect(row["name"]?.stringValue != nil)
            #expect(row["state"]?.stringValue == (row["enabled"]?.boolValue == true ? "on" : "off"))
            #expect(row["source"]?.stringValue != nil)
        }
    }

    @Test func safeModeIsReportedWhenTheAppAppliesARemoteDocument() {
        #expect(FeatureFlagsReport(features: Self.list(.nightly)).json["safe_mode"] == .null)
        let state = FeatureSafeMode.State(streaks: FeatureSafeMode.Streaks(crashes: 3, fetchFailures: 0))
        #expect(FeatureFlagsReport(features: Self.list(.nightly), safeMode: state).json["safe_mode"] == .object([
            "level": .string("last-known-good"), "crash_streak": .number(3), "fetch_failure_streak": .number(0),
        ]))
    }

    /// The Labs card's data: the report plus the next launch's local choices.
    @Test func theLabsCardAddsTheNextLaunchChoices() {
        let report = FeatureFlagsReport(features: Self.list(.dev))
        let labs = report.labsJSON(nextLocal: FeatureLocalOverrides(values: ["perfThing": false]))
        #expect(labs["next_local"] == .object(["perfThing": .bool(false)]))
        #expect(labs["features"] == report.json["features"])
        #expect(report.json["next_local"] == nil)
    }

    /// A live Debug toggle shows as the feature's value, source `local`, while it answers a
    /// value; unset (nil), the launch's resolution shows.
    @Test func aLiveToggleReportsWhatTheAppRunsWith() throws {
        func report(_ toggle: Bool?) -> FeatureFlagsReport {
            FeatureFlagsReport(features: Self.list(.dev), liveLocal: ["perfThing": { toggle }])
        }
        func row(_ toggle: Bool?) throws -> FeatureFlagsReport.JSONValue { try #require(report(toggle).json["features"]?.arrayValue?.first) }
        #expect(try row(nil)["source"] == .string("remote"))
        #expect(try row(nil)["state"] == .string("on"))
        #expect(report(false).resolution(of: Self.registry.features[0]) == Feature.Resolution(isEnabled: false, source: .local))
        #expect(try row(false)["state"] == .string("off"))
        #expect(try row(false)["source"] == .string("local"))
        #expect(try row(true)["state"] == .string("on"))
        #expect(report(true).entries.map { $0.resolution.source } == [.local, .policy, .environment])
    }

    /// Hang reports and Sentry read ``FeatureFlagsReport/fieldState``: a live toggle that
    /// flips a feature changes the hash and names the feature as a `local` override, the same hash
    /// `features_hash` reports; a toggle that answers the launch's value keeps the hash.
    @Test func aLiveToggleChangesTheFieldStateThatHangReportsAndSentryName() throws {
        let launch = FeatureFlagsReport(features: Self.list(.nightly)).fieldState
        #expect(launch == Self.list(.nightly).fieldState)
        let flipped = FeatureFlagsReport(features: Self.list(.nightly), liveLocal: ["perfThing": { false }])
        let state = flipped.fieldState
        #expect(state.hash != launch.hash)
        #expect(flipped.json["features_hash"] == .string(state.hash))
        #expect(launch.nonDefault.contains(FeatureFieldState.Entry(name: "perfThing", isEnabled: true, source: .remote)))
        #expect(state.nonDefault.contains(FeatureFieldState.Entry(name: "perfThing", isEnabled: false, source: .local)))
        #expect(!state.nonDefault.contains { $0.name == "perfThing" && $0.source == .remote })
        let same = FeatureFlagsReport(features: Self.list(.nightly), liveLocal: ["perfThing": { true }]).fieldState
        #expect(same.hash == launch.hash)
        #expect(same.nonDefault.contains(FeatureFieldState.Entry(name: "perfThing", isEnabled: true, source: .local)))
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

    /// The daemon outlives the app: its answer to the last hello shows on each row it
    /// concerns, a kill switch it turned off as `applied` and a value it keeps until it restarts as `pending`.
    @Test func theDaemonsAnswerMarksPendingAndAppliedRows() throws {
        let hello = DaemonFeatureHello(hash: "h", values: [:])
        #expect(FeatureFlagsReport(features: Self.list(.release), daemon: hello).json["daemon"] == .null)
        let answer = #"{"hash":"d1","applied":["killThing"],"pending":[{"name":"perfThing","app":true,"daemon":false}]}"#
        hello.record(try JSONDecoder().decode(ClientHelloRequest.FeatureReport.self, from: Data(answer.utf8)))
        let report = FeatureFlagsReport(features: Self.list(.release), daemon: hello).json
        #expect(report["daemon"] == .object([
            "hash": .string("d1"),
            "applied": .array([.string("killThing")]),
            "pending": .array([.object(["name": .string("perfThing"), "app": .bool(true), "daemon": .bool(false)])]),
        ]))
        let rows = try #require(report["features"]?.arrayValue)
        #expect(rows.map { $0["daemon"]?.stringValue } == ["pending", "applied", nil])
        #expect(rows.map { $0["daemon_enabled"]?.boolValue } == [false, false, nil])
        // perfThing is an app feature here: only the app reads it, so its row is the app's value.
        #expect(rows[0]["state"] == .string("on"))
    }

    /// A `both` feature the daemon keeps another value of runs with the daemon's value in the app too, once the
    /// session settles, and its row says so: the value the app runs with, source `daemon`, and the app's own.
    @Test func aPendingBothRowShowsTheDaemonsValueTheAppRunsWith() throws {
        let both = Feature(index: 0, name: "energySaver", owner: "PL-test", description: "A test feature.", kind: .labs,
                           process: .both, chromiumFeature: nil, defaults: FeatureDefaults(all: false), expires: nil,
                           params: [], stories: [], sticky: false, runtimeMutable: false)
        let list = FeatureList(registry: FeatureRegistry([both]), channel: .release,
                               overrides: FeatureOverrides(environment: [FeatureOverrides.enableVariable: "energySaver"]))
        let hello = DaemonFeatureHello(hash: "h", values: ["energySaver": true])
        let answer = #"{"hash":"d1","applied":[],"pending":[{"name":"energySaver","app":true,"daemon":false}]}"#
        hello.record(try JSONDecoder().decode(ClientHelloRequest.FeatureReport.self, from: Data(answer.utf8)))
        let before = try #require(FeatureFlagsReport(features: list, daemon: hello).json["features"]?.arrayValue)
        #expect(before[0]["state"] == .string("on"), "nothing settled yet")
        hello.settle()
        let settled = FeatureFlagsReport(features: list, daemon: hello)
        #expect(settled.resolution(of: both).isEnabled == false, "every report reader names the value the app runs with")
        #expect(settled.entries.first?.resolution.isEnabled == false)
        let row = try #require(settled.json["features"]?.arrayValue?.first)
        #expect(row["state"] == .string("off"))
        #expect(row["enabled"] == .bool(false))
        #expect(row["source"] == .string("daemon"))
        #expect(row["app_enabled"] == .bool(true))
        #expect(row["daemon"] == .string("pending"))
    }
}
