import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
@testable import CmuxNextTrace
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p09-observability task 020: `trace.start`, `trace.stop` and `trace.status` on a release router. A remote
/// relay or app caller is refused before anything runs, no parameter is a path or a command, `keys` is off
/// unless asked for and while secure input is on, the cap stops a forgotten recording, and the app's ring
/// swaps its writers to the recording ring and back.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TraceControlTests {
    // MARK: - Policy

    @Test func remoteRelayAndAppCallersAreRefusedBeforeAnythingRuns() async throws {
        let fixture = Fixture()
        for method in ["trace.start", "trace.stop", "trace.status"] {
            let relayed = await fixture.router.handle(ControlRequest(id: "1", method: method, params: ["origin": "remote"]))
            #expect(Self.code(relayed) == "forbidden", "\(method) served a remote relay caller")
            let fromApp = await fixture.router.handle(ControlRequest(id: "2", method: method, params: [:], callerApp: "some.app"))
            #expect(Self.code(fromApp) == "forbidden", "\(method) served a cmux app caller")
        }
        #expect(fixture.app.starts.isEmpty)
        #expect(fixture.daemon.commands.isEmpty)
    }

    @Test func pathAndCommandParamsAreRefused() async throws {
        let fixture = Fixture()
        for name in ["path", "out", "dir", "command", "initial_command"] {
            let reply = await fixture.router.handle(ControlRequest(id: "1", method: "trace.start", params: [name: "/tmp/x"]))
            #expect(Self.code(reply) == "invalid_params", "trace.start took params.\(name)")
        }
        let stop = await fixture.router.handle(ControlRequest(id: "2", method: "trace.stop", params: ["path": "/tmp/x"]))
        #expect(Self.code(stop) == "invalid_params")
        #expect(fixture.app.starts.isEmpty)
    }

    @Test func secondsCapIsBoundedAndTheKeyCategoryNeedsKeys() async throws {
        let fixture = Fixture()
        for cap: JSONValue in [0, 601, 1.5, "60"] {
            let reply = await fixture.router.handle(ControlRequest(id: "1", method: "trace.start", params: ["seconds_cap": cap]))
            #expect(Self.code(reply) == "invalid_params", "seconds_cap \(cap) was taken")
        }
        let key = await fixture.router.handle(ControlRequest(id: "2", method: "trace.start", params: ["categories": ["key"]]))
        #expect(Self.code(key) == "invalid_params")
        let unknown = await fixture.router.handle(ControlRequest(id: "3", method: "trace.start", params: ["categories": ["nope"]]))
        #expect(Self.code(unknown) == "invalid_params")
        #expect(fixture.app.starts.isEmpty)
    }

    @Test func releaseRouterServesTheTraceMethods() {
        let fixture = Fixture()
        for method in ["trace.start", "trace.stop", "trace.status"] {
            #expect(fixture.router.method(named: method) != nil)
        }
    }

    // MARK: - Keys

    @Test func keysAreOffByDefault() async throws {
        let fixture = Fixture()
        let reply = try await fixture.router.handle(ControlRequest(id: "1", method: "trace.start", params: [:])).get()
        #expect(reply["keys"] == false)
        #expect(reply["key_flows"] == "off")
        #expect(reply["categories"]?.arrayValue?.contains("key") == false)
        #expect(fixture.app.starts.map(\.keys) == [false])
        #expect(fixture.app.starts.first.map { $0.categoryMask & TraceCategories.key.rawValue } == 0)
        #expect(fixture.keyFlows.changes.isEmpty)
        #expect(fixture.daemon.commands == [.start(categories: nil, keys: false)])
        _ = try await fixture.router.handle(ControlRequest(id: "2", method: "trace.stop", params: [:])).get()
    }

    @Test func keysTrueStartsFlowsUnlessSecureInputIsOn() async throws {
        let fixture = Fixture()
        let reply = try await fixture.router.handle(ControlRequest(id: "1", method: "trace.start", params: ["keys": true])).get()
        #expect(reply["keys"] == true)
        #expect(reply["key_flows"] == "on")
        #expect(fixture.keyFlows.changes == [true])
        _ = try await fixture.router.handle(ControlRequest(id: "2", method: "trace.stop", params: [:])).get()
        #expect(fixture.keyFlows.changes == [true, false])

        let secure = Fixture(secureInput: true)
        let refused = try await secure.router.handle(ControlRequest(id: "3", method: "trace.start", params: ["keys": true])).get()
        #expect(refused["keys"] == false)
        #expect(refused["keys_refused"] == "secure_input")
        #expect(secure.app.starts.map(\.keys) == [false])
        #expect(secure.keyFlows.changes.isEmpty)
        #expect(secure.daemon.commands == [.start(categories: nil, keys: false)])
    }

    // MARK: - Status, stop and cap

    @Test func statusReportsTheRecordingAndStopReturnsThePaths() async throws {
        let fixture = Fixture()
        let idle = try await fixture.router.handle(ControlRequest(id: "1", method: "trace.status", params: [:])).get()
        #expect(idle["recording"] == false)
        #expect(idle["app"]?["state"] == "idle")

        let started = try await fixture.router.handle(ControlRequest(
            id: "2", method: "trace.start", params: ["categories": ["frame", "motion"], "seconds_cap": 30])).get()
        #expect(started["app"]?["state"] == "recording")
        // trace.status asks the daemon for its part too (its reply's `daemon`), so the idle status is the first command.
        #expect(fixture.daemon.commands == [.status, .start(categories: ["frame", "motion"], keys: false)])
        let again = await fixture.router.handle(ControlRequest(id: "3", method: "trace.start", params: [:]))
        #expect(Self.code(again) == "already_recording")

        let status = try await fixture.router.handle(ControlRequest(id: "4", method: "trace.status", params: [:])).get()
        #expect(status["recording"] == true)
        #expect(status["seconds_cap"] == 30)
        #expect(status["categories"] == ["frame", "motion"])
        #expect(status["app"]?["path"] == .string(FakeApp.path))

        let stopped = try await fixture.router.handle(ControlRequest(id: "5", method: "trace.stop", params: [:])).get()
        #expect(stopped["stopped_by"] == "request")
        #expect(stopped["app"]?["state"] == "stopped")
        #expect(stopped["app"]?["path"] == .string(FakeApp.path))
        #expect(stopped["daemon"]?["op"] == "stop")
        #expect(fixture.app.stops == 1)

        let none = await fixture.router.handle(ControlRequest(id: "6", method: "trace.stop", params: [:]))
        #expect(Self.code(none) == "not_recording")
        let after = try await fixture.router.handle(ControlRequest(id: "7", method: "trace.status", params: [:])).get()
        #expect(after["recording"] == false)
        #expect(after["last_stop"]?["stopped_by"] == "request")
    }

    @Test func capStopsAForgottenRecording() async throws {
        let fixture = Fixture()
        var stops = fixture.daemon.stops.makeAsyncIterator()
        _ = try await fixture.router.handle(ControlRequest(id: "1", method: "trace.start", params: ["seconds_cap": 5])).get()
        try await fixture.clock.waitForSleeper()
        fixture.clock.advance(by: .seconds(4))
        #expect(fixture.app.stops == 0)
        fixture.clock.advance(by: .seconds(1))
        _ = await stops.next()
        #expect(fixture.daemon.commands.last == .stop)
        let status = try await fixture.router.handle(ControlRequest(id: "2", method: "trace.status", params: [:])).get()
        #expect(status["recording"] == false)
        #expect(status["last_stop"]?["stopped_by"] == "cap")
        // The status asks the daemon after the cap's stop.
        #expect(Array(fixture.daemon.commands.suffix(2)) == [.stop, .status])
    }

    @Test func aMissingDaemonOrRingIsReportedNotFatal() async throws {
        let control = TraceControl(parts: TraceControlParts(app: RuntimeTraceRecording(blackBox: nil, work: InlineFiles()),
                                                            secureInput: FakeSecureInput(active: false)),
                                   clock: ManualClock())
        let router = Self.router(control)
        let reply = try await router.handle(ControlRequest(id: "1", method: "trace.start", params: ["chromium": true])).get()
        #expect(reply["app"]?["reason"] == "no_recording_ring")
        #expect(reply["daemon"]?["reason"] == "unsupported")
        #expect(reply["chromium"]?["reason"] == "unsupported")
        _ = try await router.handle(ControlRequest(id: "2", method: "trace.stop", params: [:])).get()
    }

    // MARK: - The app's ring

    /// The black box maps its recording ring once; a start moves every writer there with the requested
    /// categories and the key category off, a stop moves them back with the black box's categories.
    @Test func runtimeRecordsIntoTheRecordingRingAndBack() throws {
        let folder = NSTemporaryDirectory() + "trace-control-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let runtime = TraceRuntime(role: .app)
        let blackBox = TraceBlackBox(role: .app, directory: folder, runtime: runtime,
                                     process: .init(pid: UInt32(bitPattern: getpid())))
        #expect(runtime.startRecording(Self.frameRequest) == .idle, "a start with no recording ring started")
        #expect(blackBox.prepareRecording())
        #expect(FileManager.default.fileExists(atPath: blackBox.recordingPath))

        let started = runtime.startRecording(Self.frameRequest)
        let bytes = TraceRingLayout(TraceRuntime.Role.app.recordingSizes).totalBytes
        #expect(started == .recording(ringPath: blackBox.recordingPath, bytes: bytes))
        #expect(runtime.isEnabled(.frame))
        #expect(!runtime.isEnabled(.key), "the key category recorded without keys: true")
        #expect(runtime.startRecording(Self.frameRequest) == started, "a second start changed the recording")
        runtime.write(name: 7, categoryBit: Self.frameBit, phase: .instant, arg0: 42)
        #expect(blackBox.ring.records().contains { $0.arg0 == 42 })

        #expect(runtime.stopRecording() == .stopped(ringPath: blackBox.recordingPath, bytes: bytes))
        #expect(runtime.categories == .blackBox)
        #expect(runtime.recordingStatus == .idle)
        #expect(!blackBox.ring.records().contains { $0.arg0 == 42 }, "the black box holds the recording's record")
        let recorded = try #require(TraceRingFile.records(atPath: blackBox.recordingPath))
        #expect(recorded.contains { $0.arg0 == 42 })

        // A second recording reads only its own records.
        _ = runtime.startRecording(Self.frameRequest)
        #expect(!blackBox.ring.records().contains { $0.arg0 == 42 })
        runtime.stopRecording()
    }

    // MARK: - Helpers

    /// The frame category's bit (``TraceCategories/frame``).
    static let frameBit: UInt8 = 10
    static let frameRequest = TraceRuntime.RecordingRequest(categoryMask: TraceCategories.frame.rawValue, recordCapacity: 0)

    static func code(_ result: Result<CmuxNextSettings.JSONValue, ControlError>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.code
    }

    static func router(_ control: TraceControl) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(), configuration: .init(allowsDebugMethods: false))
        router.register(control.methods)
        return router
    }

    /// A trace control over fakes, on a release router.
    struct Fixture {
        let app = FakeApp()
        let daemon = FakeDaemon()
        let keyFlows = FakeKeyFlows()
        let clock = ManualClock()
        let router: ControlRouter

        init(secureInput: Bool = false) {
            let parts = TraceControlParts(app: app, daemon: daemon, keyFlows: keyFlows, secureInput: FakeSecureInput(active: secureInput))
            router = TraceControlTests.router(TraceControl(parts: parts, clock: clock))
        }
    }
}

extension TraceControlTests {
    /// The app's ring: records each start and stop.
    final class FakeApp: TraceAppRecording {
        static let path = "/state/trace/app-1.recording.cmxtrace"
        private let state = Mutex<(starts: [TraceRuntime.RecordingRequest], stops: Int, running: Bool)>(([], 0, false))

        var starts: [TraceRuntime.RecordingRequest] { state.withLock { $0.starts } }
        var stops: Int { state.withLock { $0.stops } }

        func prepare() async -> Bool { true }

        func start(_ request: TraceRuntime.RecordingRequest) -> TraceRuntime.RecordingStatus {
            state.withLock {
                $0.starts.append(request)
                $0.running = true
            }
            return .recording(ringPath: Self.path, bytes: 1024)
        }

        func stop() -> TraceRuntime.RecordingStatus {
            state.withLock {
                $0.stops += 1
                $0.running = false
            }
            return .stopped(ringPath: Self.path, bytes: 1024)
        }

        var status: TraceRuntime.RecordingStatus {
            state.withLock { $0.running } ? .recording(ringPath: Self.path, bytes: 1024) : .idle
        }
    }

    /// The daemon's side: records each command; ``stops`` yields once per `trace-stop`, the last step of a stop.
    final class FakeDaemon: TraceDaemonLink {
        private let sent = Mutex<[TraceControl.DaemonCommand]>([])
        let stops: AsyncStream<Void>
        private let stopSink: AsyncStream<Void>.Continuation
        var commands: [TraceControl.DaemonCommand] { sent.withLock { $0 } }

        init() {
            (stops, stopSink) = AsyncStream.makeStream()
        }

        func send(_ command: TraceControl.DaemonCommand) async throws -> CmuxNextSettings.JSONValue {
            sent.withLock { $0.append(command) }
            if command == .stop { stopSink.yield() }
            return switch command {
            case .start: ["op": "start", "recording": true]
            case .stop: ["op": "stop", "recording": false]
            case .status: ["op": "status", "recording": false]
            }
        }
    }

    final class FakeKeyFlows: TraceKeyFlows {
        private let seen = Mutex<[Bool]>([])
        var changes: [Bool] { seen.withLock { $0 } }
        func setKeyFlows(_ on: Bool) { seen.withLock { $0.append(on) } }
    }

    struct FakeSecureInput: TraceSecureInput {
        let active: Bool
        var isSecureInputActive: Bool { active }
    }

    /// Runs each file job inline on the caller's task (the black box under test never blocks long).
    struct InlineFiles: MayBlockRunner {
        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) { body() }
    }
}
