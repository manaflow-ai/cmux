@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The local last-hang bundles (p09-observability-125): a hang copies every live process's black box into
/// `last-hang/1` on the `.files` lane, at most ``LastHangBundles/kept`` bundles stay (the newest first), triggers
/// are rate-limited and cheap, and `trace.blackbox` names a bundle without taking a path.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LastHangBundlesTests {
    private static let deadPID: UInt32 = 999_999

    /// A trigger posts the copy to `.files` and writes nothing before it runs; the copy has every live process's
    /// black box (the app's folder and a holder's `<socket>.trace`), none of a dead one, and the cause.
    @Test func aHangCopiesEveryLiveBlackBoxOnTheFilesLane() async throws {
        let trace = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: trace) }
        let holders = trace + "/holders"
        try FileManager.default.createDirectory(atPath: holders + "/s1.trace", withIntermediateDirectories: true)
        let me = UInt32(bitPattern: getpid())
        try Self.plantRing(in: trace, role: .app, pid: me)
        try Self.plantRing(in: trace, role: .daemon, pid: Self.deadPID)
        try Self.plantRing(in: holders + "/s1.trace", role: .holder, pid: me &+ 1)
        let lane = HeldFiles()
        let bundles = Self.bundles(trace: trace, folders: { permit in [trace] + LastHangBundles.folders(in: holders, suffix: ".trace", permit) }, lane: lane)

        bundles.trigger(.mainThreadHang(.milliseconds(2_400)))
        #expect(lane.held == [.bestEffort], "the copy is one post to the files lane")
        #expect(access(bundles.directory + "/1", F_OK) != 0, "nothing is written before the files lane runs")
        try await lane.runHeld()

        let manifest = try Self.manifest(bundles.directory + "/1")
        let rings = manifest["rings"]?.arrayValue ?? []
        #expect(rings.compactMap { $0["role"]?.stringValue }.sorted() == ["app", "holder"], "every live process, no dead one")
        #expect(manifest["cause"] == ["kind": "main_thread_hang", "milliseconds": 2_400])
        #expect(manifest["remotes"] == [], "the manifest of a cmux trace record bundle")
        for ring in rings {
            let file = try #require(ring["file"]?.stringValue)
            #expect(file.hasPrefix("rings/") && file.hasSuffix(".blackbox.cmxtrace"))
            let bytes = try #require(FileManager.default.contents(atPath: bundles.directory + "/1/" + file))
            let image = try #require(TraceRing.Image(bytes: Array(bytes)), "\(file) decodes")
            #expect(Int(image.header.pid) == ring["pid"]?.intValue)
            #expect(image.records.count == 1)
        }
    }

    /// The hard limit: eight hangs leave exactly `1`...`5`, the newest first, and a stale bundle or another run's
    /// unfinished copy is deleted.
    @Test func atMostFiveBundlesStayTheNewestFirst() async throws {
        let trace = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: trace) }
        try Self.plantRing(in: trace, role: .app, pid: UInt32(bitPattern: getpid()))
        let lane = HeldFiles()
        let bundles = Self.bundles(trace: trace, folders: { _ in [trace] }, lane: lane)
        for stale in ["9", "07", ".building-\(Self.deadPID)-1"] {
            try FileManager.default.createDirectory(atPath: bundles.directory + "/" + stale, withIntermediateDirectories: true)
        }
        for index in 1 ... 8 {
            let made = try await lane.runFiles(.userVisible) { permit in bundles.captureLastHang(.slowKeyFrame(.milliseconds(60 + index)), permit) }
            #expect(made == bundles.directory + "/1")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: bundles.directory).sorted()
        #expect(left == ["1", "2", "3", "4", "5"])
        for n in 1 ... LastHangBundles.kept {
            let found = try await lane.runFiles(.userVisible) { permit in bundles.bundle(n, permit) }
            #expect(found?.cause["milliseconds"] == .number(Double(60 + 9 - n)), "bundle \(n) is the \(n)th newest")
        }
        let past = try await lane.runFiles(.userVisible) { permit in bundles.bundle(LastHangBundles.kept + 1, permit) }
        #expect(past == nil)
    }

    /// One bundle per ``LastHangBundles/minimumInterval``; a fast key frame or a short stall starts none; with the
    /// feature off nothing starts.
    @Test func triggersAreRateLimitedAndThresholded() throws {
        #expect(Duration.microseconds(Int64(LastHangBundles.slowKeyFrameMicros)) == LastHangBundles.slowKeyFrame)
        #expect(Duration.nanoseconds(Int64(LastHangBundles.minimumIntervalNanos)) == LastHangBundles.minimumInterval)
        let clock = ManualNanos()
        let lane = HeldFiles()
        let bundles = LastHangBundles(traceDirectory: "/nonexistent", ringFolders: { _ in [] }, work: lane, now: { clock.value })
        let sink = try #require(LastHangBundles.committedKeySink(nil, then: bundles))
        sink(50_000)
        #expect(lane.held.isEmpty, "a 50 ms key frame is under the threshold")
        sink(50_001)
        clock.advance(.seconds(1))
        bundles.trigger(.mainThreadHang(.seconds(3)))
        #expect(lane.held.count == 1, "one copy per interval")
        clock.advance(LastHangBundles.minimumInterval)
        bundles.trigger(.mainThreadHang(.seconds(1)))
        #expect(lane.held.count == 2)

        let watchdog = MainThreadWatchdog()
        let off = LastHangBundles(traceDirectory: "/nonexistent", ringFolders: { _ in [] }, work: lane, capturesHangs: false)
        #expect(off.attached(to: watchdog) == nil)
        #expect(watchdog.onLastHang == nil, "the lastHangBundle feature off attaches nothing")
        #expect(LastHangBundles.committedKeySink(nil, then: nil) == nil)
        off.trigger(.mainThreadHang(.seconds(5)))
        #expect(lane.held.count == 2, "the lastHangBundle feature off makes no bundle")
    }

    /// The watchdog starts a bundle at a finished stall of 1 s and up, and not below
    /// (``MainThreadWatchdog/deliverStall(_:)``); hang reports' stall sink still gets every stall.
    @Test func aFinishedStallOfOneSecondStartsALastHang() {
        let watchdog = MainThreadWatchdog()
        let causes = Collected<LastHangCause>(), stalls = Collected<Duration>()
        watchdog.onLastHang = { causes.append($0) }
        watchdog.onStall = { stalls.append($0.duration) }
        for milliseconds in [999, 1_000] {
            watchdog.deliverStall(HangRecord(sequence: 1, startUptimeNanos: 0, duration: .milliseconds(milliseconds), cpu: .zero, addresses: []))
        }
        #expect(causes.values == [.mainThreadHang(.milliseconds(1_000))])
        #expect(stalls.values == [.milliseconds(999), .milliseconds(1_000)])
    }

    /// `--now` writes `blackbox-now` with no cause and leaves the hang bundles alone.
    @Test func captureNowReplacesItsOwnBundle() async throws {
        let trace = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: trace) }
        try Self.plantRing(in: trace, role: .app, pid: UInt32(bitPattern: getpid()))
        let lane = HeldFiles()
        let bundles = Self.bundles(trace: trace, folders: { _ in [trace] }, lane: lane)
        for _ in 0 ..< 2 {
            let made = try await lane.runFiles(.userVisible) { permit in bundles.captureNow(permit) }
            #expect(made == bundles.nowDirectory)
        }
        let manifest = try Self.manifest(bundles.nowDirectory)
        #expect(manifest["cause"] == .null)
        #expect(manifest["rings"]?.arrayValue?.count == 1)
        #expect(access(bundles.directory + "/1", F_OK) != 0)
    }

    /// `trace.blackbox`: `now` by default, `last_hang` 1 to 5, never both; a remote relay, a cmux app or an unknown
    /// parameter is refused before anything runs; the reply names the bundle and its cause.
    @Test func traceBlackboxTakesNowOrALastHang() async throws {
        #expect(try TraceBlackboxControl.Request([:]) == .now)
        #expect(try TraceBlackboxControl.Request(["now": true]) == .now)
        #expect(try TraceBlackboxControl.Request(["last_hang": 5]) == .lastHang(5))
        for bad: [String: JSONValue] in [["last_hang": 0], ["last_hang": 6], ["last_hang": 1.5], ["last_hang": "1"],
                                         ["now": true, "last_hang": 1], ["now": "yes"]] {
            #expect(throws: ControlError.self, "\(bad)") { try TraceBlackboxControl.Request(bad) }
        }

        let trace = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: trace) }
        try Self.plantRing(in: trace, role: .app, pid: UInt32(bitPattern: getpid()))
        let lane = HeldFiles()
        let bundles = Self.bundles(trace: trace, folders: { _ in [trace] }, lane: lane)
        let control = TraceBlackboxControl(bundles: bundles, work: lane)
        await #expect(throws: ControlError.self, "no bundle yet") { try await control.reply(Self.call(["last_hang": 1])) }
        _ = try await lane.runFiles(.userVisible) { permit in bundles.captureLastHang(.slowKeyFrame(.milliseconds(80)), permit) }
        let reply = try await control.reply(Self.call(["last_hang": 1]))
        #expect(reply["bundle"] == .string(bundles.directory + "/1"))
        #expect(reply["cause"] == ["kind": "slow_key_frame", "milliseconds": 80])
        let now = try await control.reply(Self.call([:]))
        #expect(now["bundle"] == .string(bundles.nowDirectory))

        for (params, callerApp) in [(["origin": "remote"], nil), (["path": "/tmp/x"], nil), ([:], "com.example.app")] as [([String: JSONValue], String?)] {
            await #expect(throws: ControlError.self, "\(params) \(callerApp ?? "")") {
                try await control.reply(Self.call(params, callerApp: callerApp))
            }
        }
    }

    // MARK: - Fixtures

    private static func bundles(trace: String, folders: @escaping @Sendable (borrowing BlockingPermit) -> [String], lane: HeldFiles) -> LastHangBundles {
        LastHangBundles(traceDirectory: trace, ringFolders: folders, work: lane,
                        isAlive: { pid, _ in pid != Int32(bitPattern: deadPID) })
    }

    private static func call(_ params: [String: JSONValue], callerApp: String? = nil) -> ControlCall {
        ControlCall(request: ControlRequest(id: "1", method: "trace.blackbox", params: params, callerApp: callerApp),
                    snapshot: .empty, connection: ControlConnectionID(rawValue: 1), deadline: .now + .seconds(20))
    }

    /// A black box of `role` in process `pid` with one record, as `<stem>-<pid>.blackbox.cmxtrace` in `folder`.
    private static func plantRing(in folder: String, role: TraceRing.Role, pid: UInt32) throws {
        let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 16, threadCapacity: 16, chunkCount: 4),
                             identity: TraceRing.Identity(pid: pid, role: role))
        ring.write(name: 1, phase: .instant, timestamp: 1_000)
        let path = folder + "/" + TraceRingFile.fileName(role: role, pid: pid)
        #expect(FileManager.default.createFile(atPath: path, contents: Data(ring.image())))
    }

    private static func manifest(_ bundle: String) throws -> JSONValue {
        try JSONValue.parse(try #require(FileManager.default.contents(atPath: bundle + "/manifest.json")))
    }

    private static func temporaryFolder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "last-hang-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

/// Values a sink got, in order.
private final class Collected<Value: Sendable>: Sendable {
    // concurrency-allow: the values a sink appends and the test reads after (lock carve-out: a list, no I/O under it).
    private let list = Mutex<[Value]>([])
    var values: [Value] { list.withLock { $0 } }
    func append(_ value: Value) { list.withLock { $0.append(value) } }
}

/// A clock the test moves.
private final class ManualNanos: Sendable {
    private let nanos = Atomic<UInt64>(1_000_000_000)
    var value: UInt64 { nanos.load(ordering: .relaxed) }
    func advance(_ duration: Duration) {
        _ = nanos.add(UInt64(duration.components.seconds) * 1_000_000_000, ordering: .relaxed)
    }
}

/// Holds each posted files job until ``runHeld()``, which runs them on a real `.files` lane; runs `runFiles` there.
private final class HeldFiles: MayBlockRunner {
    private let lanes = BackgroundWork(label: "test.last-hang")
    // concurrency-allow: the posted jobs, appended by the poster and taken by the test (lock carve-out: a list, no I/O under it).
    private let items = Mutex<[(priority: MayBlockPriority, body: @Sendable () -> Void)]>([])

    /// The priorities of the jobs posted and not run yet, in post order.
    var held: [MayBlockPriority] { items.withLock { $0.map(\.priority) } }

    /// Runs every held job on the `.files` lane, in post order.
    func runHeld() async throws {
        let bodies = items.withLock { held in
            defer { held.removeAll() }
            return held.map(\.body)
        }
        try await lanes.runFiles(.userVisible) { for body in bodies { body() } }
    }

    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
    }

    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
    }

    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
    }

    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void) {
        items.withLock { $0.append((priority, body)) }
    }
}
