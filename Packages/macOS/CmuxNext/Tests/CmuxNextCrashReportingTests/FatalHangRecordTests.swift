import CmuxNextCompat
import CmuxNextTrace
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// The record a run keeps on disk while its main thread hangs, and the one "fatal app hang"
/// event the next launch makes of it. The stack is stored as image and offset, so the event's frames and debug_meta
/// are those of the hung process; the record is read once; a clean or crashed run's record is never reported.
@Suite(.serialized) struct FatalHangRecordTests {
    private static let uuid = "A1B2C3D4-0000-4000-8000-000000000001"
    private static let image = MainThreadHangEvent.Image(base: 0x1_0000, size: 0x1000, uuid: uuid,
                                                         path: "/Users/someone/Applications/cmux.app/Contents/MacOS/cmux")

    private static func record(pid: Int32 = 4242, startedAt: Date = Date(), addresses: [UInt] = [0x1_0010, 0x1_0800, 0x99],
                               loaded: [MainThreadHangEvent.Image] = [image]) -> FatalHangRecord {
        FatalHangRecord(pid: pid, startedAt: startedAt, startUptimeNanos: 7_000_000_000, elapsedNanos: 3_000_000_000,
                        addresses: addresses, loaded: loaded, phase: "cef_pump",
                        attribution: .init(owner: "workspace.new", taskClass: "input", location: "CmuxNextApp/A.swift:1", turnNanos: 1),
                        release: "cmux-next@1.0+1", dist: "1")
    }

    private static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "fatal-hang-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func framesAreKeptAsImageAndOffsetAndTheImageByItsFileNameOnly() {
        let record = Self.record()
        #expect(record.images == [.init(uuid: Self.uuid, name: "cmux", base: 0x1_0000, size: 0x1000)])
        #expect(record.frames == [.init(image: 0, offset: 0x10), .init(image: 0, offset: 0x800), .init(image: nil, offset: 0x99)])
        #expect(record.addresses == [0x1_0010, 0x1_0800, 0x99])
    }

    @Test func aRecordKeepsAtMost64FramesAnd16Images() {
        let images = (0..<20).map { index in
            MainThreadHangEvent.Image(base: UInt64(0x10_0000 * (index + 1)), size: 0x1000,
                                      uuid: String(format: "A1B2C3D4-0000-4000-8000-%012d", index), path: "/usr/lib/lib\(index).dylib")
        }
        let addresses = (0..<70).map { UInt(0x10_0000 * ($0 % 20 + 1) + 4) }
        let record = Self.record(addresses: addresses, loaded: images)
        #expect(record.frames.count == FatalHangRecord.maxFrames)
        #expect(record.images.count == FatalHangRecord.maxImages)
        #expect(record.frames[16] == .init(image: nil, offset: UInt64(addresses[16])), "a 17th image's frame keeps its raw address")
        #expect(record.addresses == Array(addresses.prefix(64)))
    }

    @Test func theEventIsOneFatalAppHangWithTheHungStackAndItsImages() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let event = Self.record(startedAt: started).event()
        #expect(event.level == .fatal)
        #expect(event.timestamp == started)
        #expect(event.releaseName == "cmux-next@1.0+1")
        let exception = try #require(event.exceptions?.first)
        #expect(event.exceptions?.count == 1)
        #expect(exception.type == "FatalAppHang")
        #expect(exception.mechanism?.handled == false)
        // Outermost first: the unmapped frame, then the two in the image.
        #expect(exception.stacktrace?.frames.map(\.instructionAddress) == ["0x99", "0x10800", "0x10010"])
        #expect(exception.stacktrace?.frames.last?.imageAddress == "0x10000")
        #expect(event.threads?.count == 1)
        #expect(event.threads?.first?.crashed == true)
        let meta = try #require(event.debugMeta?.first)
        #expect(event.debugMeta?.count == 1)
        #expect(meta.debugID == Self.uuid)
        #expect(meta.imageAddress == "0x10000")
        #expect(meta.codeFile == "cmux", "never a path under the home folder")
        #expect(event.tags?["hang_fatal"] == "true")
        #expect(event.tags?["main_thread_phase"] == "cef_pump")
        #expect(event.tags?["hang_owner"] == "workspace.new")
        #expect(event.extra?["hang_ms"] as? Int == 3_000)
    }

    @Test func aRecordIsTakenOnce() throws {
        let folder = try Self.folder("take")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: FatalHangRecorder.fileName(pid: 4242))
        let record = Self.record()
        try JSONEncoder().encode(record).write(to: url)
        #expect(FatalHangRecord.take(at: url) == record)
        #expect(FatalHangRecord.take(at: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRecordBelongsOnlyToTheRunThatWroteIt() {
        let launched = Date(timeIntervalSince1970: 1_800_000_000)
        let record = Self.record(startedAt: launched.addingTimeInterval(60))
        #expect(record.belongs(toRunOf: 4242, launchedAt: launched))
        #expect(!record.belongs(toRunOf: 4243, launchedAt: launched), "another pid")
        #expect(!record.belongs(toRunOf: 4242, launchedAt: launched.addingTimeInterval(120)), "a reused pid's later run")
    }

    // MARK: the recorder

    /// The watchdog thread's three calls: the record is on disk from the threshold, follows each checkpoint and is
    /// gone once the main thread answers; an end with no record does nothing.
    @Test func aHangIsOnDiskWhileItLastsAndGoneWhenItEnds() throws {
        let folder = try Self.folder("recorder")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = FatalHangRecorder(directory: folder, release: "r", dist: "d", pid: 4242)
        recorder.ended()
        #expect(!FileManager.default.fileExists(atPath: recorder.file.path))
        recorder.began(startUptimeNanos: 5_000_000_000, elapsedNanos: 2_000_000_000, addresses: [0x99], phase: nil, attribution: nil)
        let written = try JSONDecoder().decode(FatalHangRecord.self, from: Data(contentsOf: recorder.file))
        #expect(written.pid == 4242)
        #expect(written.startUptimeNanos == 5_000_000_000)
        #expect(written.elapsedNanos == 2_000_000_000)
        #expect(written.frames == [.init(image: nil, offset: 0x99)], "an address no loaded image holds")
        recorder.progressed(elapsedNanos: 4_000_000_000)
        #expect(try JSONDecoder().decode(FatalHangRecord.self, from: Data(contentsOf: recorder.file)).elapsedNanos == 4_000_000_000)
        recorder.ended()
        #expect(!FileManager.default.fileExists(atPath: recorder.file.path))
        #expect(!recorder.hasRecord)
        recorder.progressed(elapsedNanos: 8_000_000_000)
        #expect(!FileManager.default.fileExists(atPath: recorder.file.path), "a checkpoint after the end writes nothing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "no temporary file left")
    }

    /// The next launch: a planted record of the previous run gives 1 record; every other process's record and a
    /// half-written one are removed; this process's own file and other files stay.
    @Test func theNextLaunchTakesThePreviousRunsRecordOnceAndClearsTheRest() throws {
        let folder = try Self.folder("launch")
        defer { try? FileManager.default.removeItem(at: folder) }
        let launched = Date().addingTimeInterval(-60)
        for pid: Int32 in [4242, 4243, 4999] {
            FatalHangRecorder(directory: folder, release: "r", dist: "d", pid: pid)
                .began(startUptimeNanos: 1, elapsedNanos: 2_000_000_000, addresses: [], phase: nil, attribution: nil)
        }
        try Data("{".utf8).write(to: folder.appending(path: ".hang-4244.json.tmp"))
        try Data("{}".utf8).write(to: folder.appending(path: "run.json"))
        let taken = FatalHangRecorder.takePrevious(in: folder, run: (pid: 4242, launched: launched), currentPID: 4999)
        #expect(taken?.pid == 4242)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["run.json", FatalHangRecorder.fileName(pid: 4999)])
        #expect(FatalHangRecorder.takePrevious(in: folder, run: (pid: 4242, launched: launched), currentPID: 4999) == nil, "reported once")
    }

    /// A clean quit or a crash (`run` nil) reports nothing and still clears the record; a reused pid's older record
    /// is not the previous run's.
    @Test func aCleanOrCrashedRunOrAnOlderRecordGivesNone() throws {
        let folder = try Self.folder("none")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = FatalHangRecorder(directory: folder, release: "r", dist: "d", pid: 4242)
        recorder.began(startUptimeNanos: 1, elapsedNanos: 2_000_000_000, addresses: [], phase: nil, attribution: nil)
        #expect(FatalHangRecorder.takePrevious(in: folder, run: nil, currentPID: 1) == nil)
        #expect(!FileManager.default.fileExists(atPath: recorder.file.path))
        recorder.began(startUptimeNanos: 1, elapsedNanos: 2_000_000_000, addresses: [], phase: nil, attribution: nil)
        #expect(FatalHangRecorder.takePrevious(in: folder, run: (pid: 4242, launched: Date().addingTimeInterval(3_600)), currentPID: 1) == nil)
    }

    // MARK: the crash-key page

    /// `hang_in_progress_frames` words are the image index (high 16 bits) and offset; `hang_in_progress_images` are the
    /// UUID's bytes as two little-endian words.
    @Test func theCrashKeyWordsAreImageAndOffsetAndTheUUIDsBytes() {
        let record = Self.record()
        #expect(record.crashKeyFrames == [0x10, 0x800, UInt64(FatalHangRecord.crashKeyNoImage) << 48 | 0x99])
        // A1 B2 C3 D4 00 00 40 00 | 80 00 00 00 00 00 00 01
        #expect(record.crashKeyImageUUIDWords == [0x0040_0000_D4C3_B2A1, 0x0100_0000_0000_0080])
        #expect(FatalHangRecord.uuidWords("not a uuid") == [0, 0])
    }

    /// While a hang lasts the page names it with the record's frames and images, so a crash during it carries them;
    /// once the main thread answers the page has no hang in progress.
    @Test func aHangInProgressIsOnTheCrashKeyPageUntilItEnds() throws {
        let folder = try Self.folder("keys")
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = TraceRuntime(role: .app)
        let page = CrashKeyPage(identity: .init(role: .app))
        #expect(runtime.attachCrashKeys(page))
        let recorder = FatalHangRecorder(directory: folder, release: "r", dist: "d", runtime: runtime, pid: 4242)
        recorder.began(startUptimeNanos: 5_000_000_000, elapsedNanos: 2_000_000_000, addresses: [0x99, 0x77], phase: nil, attribution: nil)
        let written = try JSONDecoder().decode(FatalHangRecord.self, from: Data(contentsOf: recorder.file))
        let hang = try #require(page.snapshot().hangInProgress)
        #expect(hang.startNanos == 5_000_000_000)
        #expect(hang.frames == written.crashKeyFrames)
        #expect(hang.frames.count == 2)
        #expect(Array(hang.imageUUIDWords.prefix(written.crashKeyImageUUIDWords.count)) == written.crashKeyImageUUIDWords)
        recorder.ended()
        #expect(page.snapshot().hangInProgress == nil)
    }

    // MARK: the next launch's send

    private struct InlineFiles: MayBlockRunner {
        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) { body() }
    }

    /// The events the capture seam got.
    private final class Captured: Sendable {
        let count = Atomic(0)
    }

    private static let reporter = CrashReporter(policy: CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:]))

    /// A run with pid 4242 that hung for 3 s and left its record in `folder`.
    private static func plantHungRun(in folder: URL) {
        FatalHangRecorder(directory: folder, release: "cmux-next@1.0+1", dist: "1", runtime: TraceRuntime(role: .app), pid: 4242)
            .began(startUptimeNanos: 1, elapsedNanos: 3_000_000_000, addresses: [0x99], phase: nil, attribution: nil)
    }

    /// How many events one next-launch report of `folder` sends.
    private static func sentEvents(in folder: URL, run: (pid: Int32, launched: Date)?, enabled: Bool) -> Int {
        let captured = Captured()
        reporter.reportPreviousFatalHang(in: folder, run: run, enabled: enabled, traceDirectory: folder.appending(path: "trace"),
                                         hangReportsOptIn: false, work: InlineFiles(), currentPID: 1, consented: { true },
                                         capture: { event, _ in
                                             #expect(event.exceptions?.first?.type == "FatalAppHang")
                                             #expect(event.releaseName == "cmux-next@1.0+1", "the hung build's release")
                                             _ = captured.count.add(1, ordering: .relaxed)
                                         })
        return captured.count.load(ordering: .relaxed)
    }

    @Test func aKilledRunsPlantedRecordSendsOneEvent() throws {
        let folder = try Self.folder("send")
        defer { try? FileManager.default.removeItem(at: folder) }
        Self.plantHungRun(in: folder)
        let run = (pid: Int32(4242), launched: Date().addingTimeInterval(-60))
        #expect(Self.sentEvents(in: folder, run: run, enabled: true) == 1)
        #expect(Self.sentEvents(in: folder, run: run, enabled: true) == 0, "a record is sent once")
    }

    /// A clean quit or a crash: the run marker gives no unreported run.
    @Test func aQuitOrACrashSendsNone() throws {
        let folder = try Self.folder("send-none")
        defer { try? FileManager.default.removeItem(at: folder) }
        Self.plantHungRun(in: folder)
        #expect(Self.sentEvents(in: folder, run: nil, enabled: true) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "the record was not cleared")
    }

    /// The kill switch off: nothing goes out, and the record is cleared so that turning it on later sends nothing old.
    @Test func theKillSwitchOffSendsNoneAndClearsTheRecord() throws {
        let folder = try Self.folder("send-off")
        defer { try? FileManager.default.removeItem(at: folder) }
        Self.plantHungRun(in: folder)
        let run = (pid: Int32(4242), launched: Date().addingTimeInterval(-60))
        #expect(Self.sentEvents(in: folder, run: run, enabled: false) == 0)
        #expect(Self.sentEvents(in: folder, run: run, enabled: true) == 0, "a record from before the switch went off was sent")
    }
}
