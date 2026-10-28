@testable import CmuxNextControl
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextTrace
import Testing

/// `metrics.snapshot` (p09-observability task 065): the field histograms since launch as JSON, read-only, with
/// `names` as its only parameter and `unavailable` while the `metricsView` feature is off. Each test records into
/// its own runtime's store and asks a router that has only the method under test.
@Suite struct MetricsControlTests {
    private static let catalog: [HistogramID] = [.mainTurn, .keyFrame(.view), .keyFrame(.terminal), .cefHelperExit,
                                                 .smoothnessDroppedPercent(.scroll)]

    /// A runtime whose metrics go to a fresh store of ``catalog``, and that store.
    private static func recordingRuntime() -> (TraceRuntime, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "7", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242, catalog: catalog)
        #expect(store.attach(to: runtime))
        return (runtime, store)
    }

    private static func router(_ runtime: TraceRuntime, enabled: Bool = true, allowsDebug: Bool = true) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(),
                                   configuration: .init(allowsDebugMethods: allowsDebug))
        router.register([ControlRouter.metricsMethod(MetricsSnapshot(runtime: runtime), enabled: enabled)])
        return router
    }

    private static func ask(_ router: ControlRouter, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "metrics.snapshot", params: params))
    }

    private static func histogram(_ name: String, in reply: JSONValue) -> JSONValue? {
        reply["histograms"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name })
    }

    private static func upperBound(_ id: HistogramID, _ sample: Int64) throws -> Int {
        let index = try #require(id.layout.bucketIndex(of: sample))
        return Int(try #require(id.layout.bucketRange(index)).upperBound)
    }

    /// The snapshot shows every sample since launch: a hang report's upload (``MetricsStore/markLogged(_:)``) lowers
    /// the next delta, never the local view, as chrome://histograms keeps its totals after a UMA upload.
    @Test func showsEveryRecordedSampleEvenAfterAnUpload() async throws {
        let (runtime, store) = Self.recordingRuntime()
        let metrics = Metrics(runtime: runtime)
        for _ in 0 ..< 3 { metrics.record(.mainTurn, 1_000) }
        store.markLogged(store.delta())
        metrics.record(.mainTurn, 2_000)
        let delta = store.delta().histograms.first(where: { $0.name == "main.turn" })
        #expect(delta?.count == 1, "the delta has only the new sample")

        let reply = try await Self.ask(Self.router(runtime)).get()
        #expect(reply["recording"] == .bool(true))
        #expect(reply["pid"] == JSONValue(4242))
        #expect(reply["profile"]?["build"] == .string("7"))
        let turns = try #require(Self.histogram("main.turn", in: reply))
        #expect(turns["count"] == JSONValue(4))
        #expect(turns["sum"] == JSONValue(5_000))
        #expect(turns["unit"] == .string("us"))
        #expect(turns["layout"]?["kind"] == .string("log_linear"))
        #expect(reply["count"] == JSONValue(1), "histograms with no sample are left out")
    }

    /// p50, p95, p99 and max are the upper bounds of the buckets that hold them; each bucket names its values.
    @Test func readsPercentilesAndBucketsFromTheBuckets() async throws {
        let (runtime, _) = Self.recordingRuntime()
        let metrics = Metrics(runtime: runtime)
        for _ in 0 ..< 90 { metrics.record(.keyFrame(.view), 1_000) }
        for _ in 0 ..< 9 { metrics.record(.keyFrame(.view), 8_000) }
        metrics.record(.keyFrame(.view), 50_000)

        let reply = try await Self.ask(Self.router(runtime)).get()
        let frames = try #require(Self.histogram("key.frame.view", in: reply))
        let id = HistogramID.keyFrame(.view)
        let fast = try Self.upperBound(id, 1_000)
        let slow = try Self.upperBound(id, 8_000)
        let slowest = try Self.upperBound(id, 50_000)
        #expect(frames["p50"] == JSONValue(fast))
        #expect(frames["p95"] == JSONValue(slow))
        #expect(frames["p99"] == JSONValue(slow))
        #expect(frames["max"] == JSONValue(slowest))
        #expect(frames["overflow_count"] == JSONValue(0))
        let buckets = try #require(frames["buckets"]?.arrayValue)
        #expect(buckets.compactMap { $0["count"] } == [JSONValue(90), JSONValue(9), JSONValue(1)])
        let first = try #require(buckets.first)
        let index = try #require(id.layout.bucketIndex(of: 1_000))
        #expect(first["index"] == JSONValue(index))
        #expect(first["low"]?.intValue.map { $0 <= 1_000 } == true)
        #expect(first["high"]?.intValue.map { $0 >= 1_000 } == true)
    }

    /// A sample past the layout's maximum counts in the overflow bucket: its `high` is null, `overflow_count` says
    /// how many, and a percentile there is the maximum plus 1.
    @Test func flagsTheOverflowBucket() async throws {
        let (runtime, _) = Self.recordingRuntime()
        guard case let .logLinear(maximum) = HistogramID.mainTurn.layout else {
            Issue.record("main.turn is log-linear")
            return
        }
        Metrics(runtime: runtime).record(.mainTurn, maximum + 1_000)

        let reply = try await Self.ask(Self.router(runtime)).get()
        let turns = try #require(Self.histogram("main.turn", in: reply))
        #expect(turns["overflow_count"] == JSONValue(1))
        #expect(turns["max"] == JSONValue(Int(maximum + 1)))
        let bucket = try #require(turns["buckets"]?.arrayValue?.first)
        #expect(bucket["high"] == .null)
        #expect(bucket["low"] == JSONValue(Int(maximum + 1)))
    }

    /// An enumeration's values have no order: its buckets are listed, with no percentiles.
    @Test func listsAnEnumerationWithoutPercentiles() async throws {
        let (runtime, _) = Self.recordingRuntime()
        Metrics(runtime: runtime).record(.cefHelperExit, 9)

        let reply = try await Self.ask(Self.router(runtime)).get()
        let exits = try #require(Self.histogram("cef.helper_exit", in: reply))
        #expect(exits["p50"] == nil)
        #expect(exits["max"] == nil)
        #expect(exits["layout"]?["kind"] == .string("enumeration"))
        let bucket = try #require(exits["buckets"]?.arrayValue?.first)
        #expect(bucket["low"] == JSONValue(9))
        #expect(bucket["high"] == JSONValue(9))
    }

    /// `names` keeps the histograms whose name contains one of them (Chrome's histogram query).
    @Test func namesKeepTheHistogramsThatContainThem() async throws {
        let (runtime, _) = Self.recordingRuntime()
        let metrics = Metrics(runtime: runtime)
        metrics.record(.mainTurn, 10)
        metrics.record(.keyFrame(.view), 10)
        metrics.record(.keyFrame(.terminal), 10)
        metrics.record(.smoothnessDroppedPercent(.scroll), 3)
        let router = Self.router(runtime)

        let frames = try await Self.ask(router, ["names": ["key.frame"]]).get()
        #expect(frames["histograms"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["key.frame.view", "key.frame.terminal"])
        let two = try await Self.ask(router, ["names": ["main.turn", "scroll"]]).get()
        #expect(two["count"] == JSONValue(2))
        let all = try await Self.ask(router, ["names": []]).get()
        #expect(all["count"] == JSONValue(4), "an empty list names every histogram")
    }

    /// `names` is the only parameter, an array of strings; anything else is refused before a counter is read.
    @Test func refusesEveryOtherParameterAndShape() async throws {
        let (runtime, _) = Self.recordingRuntime()
        let router = Self.router(runtime)
        for params: [String: JSONValue] in [["path": "/tmp/x"], ["names": "main.turn"], ["names": ["main.turn", 3]],
                                            ["names": ["main.turn"], "command": "ls"]] {
            let result = await Self.ask(router, params)
            guard case .failure(let error) = result else {
                Issue.record("accepted \(params)")
                continue
            }
            #expect(error.code == "invalid_params", "\(params)")
        }
    }

    /// While the `metricsView` feature is off the method answers `unavailable` and reads nothing.
    @Test func answersUnavailableWhileTheFeatureIsOff() async throws {
        let (runtime, _) = Self.recordingRuntime()
        Metrics(runtime: runtime).record(.mainTurn, 10)
        let result = await Self.ask(Self.router(runtime, enabled: false))
        guard case .failure(let error) = result else {
            Issue.record("served while off")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.message.contains("metricsView"))
    }

    /// A runtime with no store yet answers `recording: false` with no histogram.
    @Test func saysWhenNothingRecords() async throws {
        let reply = try await Self.ask(Self.router(TraceRuntime(role: .app))).get()
        #expect(reply["recording"] == .bool(false))
        #expect(reply["histograms"] == .array([]))
    }

    /// Not a `debug.*` method: a release router serves it. It reads on the snapshot lane from the last published
    /// snapshot, so it answers while the main thread is stalled.
    @Test func releaseRoutersServeItFromTheSnapshotLane() async throws {
        let (runtime, _) = Self.recordingRuntime()
        let router = Self.router(runtime, allowsDebug: false)
        let method = try #require(router.method(named: "metrics.snapshot"))
        #expect(method.lane == .snapshot)
        #expect(method.readsLastPublished)
        _ = try await Self.ask(router).get()
    }
}
