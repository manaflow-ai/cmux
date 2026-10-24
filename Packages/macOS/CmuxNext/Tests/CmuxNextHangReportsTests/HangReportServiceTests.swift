@testable import CmuxNextHangReports
import CmuxNextCompat
import Foundation
import Testing

/// The service sends nothing while off, sends exactly the bytes it keeps for View Hang Report,
/// retries through the outbox, caps a day, and forgets everything queued when turned off.
struct HangReportServiceTests {
    final class RecordingTransport: HangReportTransport {
        let answers: Mutex<[HangReportTransportResult]>
        let bodies = Mutex<[Data]>([])

        init(_ answers: [HangReportTransportResult] = []) { self.answers = Mutex(answers) }

        func send(_ body: Data) async -> HangReportTransportResult {
            bodies.withLock { $0.append(body) }
            return answers.withLock { $0.isEmpty ? .accepted : $0.removeFirst() }
        }

        var sent: [Data] { bodies.withLock { $0 } }
    }

    final class TestClock: Sendable {
        let date = Mutex(Date(timeIntervalSince1970: 1_792_800_000))  // 2026-10-23
        func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
        var now: Date { date.withLock { $0 } }
    }

    private let directory = FileManager().temporaryDirectory.appending(path: "hang-reports-\(UUID().uuidString)")
    private let suite = "hang-reports-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }
    private let clock = TestClock()

    /// A transport whose sends wait until the test lets them go.
    final class GatedTransport: HangReportTransport {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let bodies = Mutex<[Data]>([])

        func send(_ body: Data) async -> HangReportTransportResult {
            started.continuation.yield()
            for await _ in release.stream { break }
            bodies.withLock { $0.append(body) }
            return .accepted
        }
    }

    private func service(_ transport: any HangReportTransport, counts: @escaping @Sendable () async -> CoarseCounts = { CoarseCounts(windows: 1, workspaces: 3, panes: 4, tabs: 9) },
                         build: String = "70123", allowed: @escaping @Sendable () -> Bool = { true })
        -> HangReportService {
        let clock = clock
        let collector = HangReportCollector(resolve: { _ in [.other] }, schedule: { $0() })
        return HangReportService(
            store: HangReportStore(directory: directory), transport: transport, builder: HangReportFixtures.builder(),
            scanner: PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms),
            identity: InstallIdentity(suiteName: suite, now: { clock.now }), collector: collector,
            environment: HangReportService.Environment(
                app: HangReport.App(version: "0.70.0", build: build, channel: "nightly"), os: HangReport.OS(version: "15.7.4"),
                hardware: HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48),
                counts: counts, now: { clock.now }, stillAllowed: allowed))
    }

    @Test func offSendsNothing() async {
        let transport = RecordingTransport()
        let service = service(transport)
        service.collector.noteStall(durationNanos: 400_000_000, cpuNanos: 0, addresses: [1])
        await service.receive(HangReportFixtures.metricKitInput())
        await service.launched()
        #expect(transport.sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: service.lastReportURL.path))
    }

    @Test func aDeliverySendsOneReportAndKeepsItsReadableCopy() async throws {
        let transport = RecordingTransport()
        let service = service(transport)
        await service.setEnabled(true)
        service.collector.noteStall(durationNanos: 400_000_000, cpuNanos: 100_000_000, addresses: [1])
        await service.receive(HangReportFixtures.metricKitInput())
        let body = try #require(transport.sent.first)
        #expect(transport.sent.count == 1)
        let sent = try JSONDecoder().decode(HangReport.self, from: body)
        let kept = try JSONDecoder().decode(HangReport.self, from: Data(contentsOf: service.lastReportURL))
        #expect(sent == kept)
        #expect(sent.stallHistogram == [HistogramBucket(lowMs: 250, highMs: 500, count: 1)])
        #expect(sent.hangs.contains { $0.source == .metrickit })
        #expect(sent.counts == CoarseCounts(windows: 1, workspaces: 3, panes: 4, tabs: 9))
        #expect(await service.viewableReport() == service.lastReportURL)
    }

    @Test func aFailedSendWaitsInTheOutboxForTheNextTrigger() async throws {
        let transport = RecordingTransport([.retryLater])
        let service = service(transport)
        await service.setEnabled(true)
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(transport.sent.count == 1)
        await service.launched()
        #expect(transport.sent.count == 2)
        #expect(transport.sent[0] == transport.sent[1])
        await service.launched()
        #expect(transport.sent.count == 2)
    }

    @Test func atMostFourReportsADay() async {
        let transport = RecordingTransport()
        let service = service(transport)
        await service.setEnabled(true)
        for _ in 0..<6 { await service.receive(HangReportFixtures.metricKitInput()) }
        #expect(transport.sent.count == HangReportService.dailyLimit)
        clock.advance(24 * 60 * 60)
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(transport.sent.count == HangReportService.dailyLimit + 1)
    }

    @Test func aLaunchSendsTheWatchdogsFindingsOncePerDay() async {
        let transport = RecordingTransport()
        let service = service(transport)
        await service.setEnabled(true)
        service.collector.noteStall(durationNanos: 300_000_000, cpuNanos: 0, addresses: [1])
        await service.launched()
        #expect(transport.sent.count == 1)
        service.collector.noteStall(durationNanos: 300_000_000, cpuNanos: 0, addresses: [1])
        await service.launched()
        #expect(transport.sent.count == 1)
        clock.advance(25 * 60 * 60)
        await service.launched()
        #expect(transport.sent.count == 2)
    }

    @Test func savedFindingsReachTheNextLaunchsReport() async throws {
        let first = service(RecordingTransport())
        await first.setEnabled(true)
        first.collector.noteStall(durationNanos: 600_000_000, cpuNanos: 0, addresses: [1])
        first.saveForNextLaunch()
        let transport = RecordingTransport()
        let second = service(transport)
        await second.setEnabled(true)
        await second.launched()
        let sent = try JSONDecoder().decode(HangReport.self, from: #require(transport.sent.first))
        #expect(sent.stallHistogram == [HistogramBucket(lowMs: 500, highMs: 1_000, count: 1)])
    }

    @Test func turningOffForgetsTheQueueAndTheInstallID() async {
        let transport = RecordingTransport([.retryLater])
        let service = service(transport)
        await service.setEnabled(true)
        await service.receive(HangReportFixtures.metricKitInput())
        let id = defaults.string(forKey: InstallIdentity.idKey)
        #expect(id != nil)
        await service.setEnabled(false)
        #expect(defaults.string(forKey: InstallIdentity.idKey) == nil)
        await service.setEnabled(true)
        await service.launched()
        #expect(transport.sent.count == 1)
    }

    @Test func turningOffWhileAReportIsBuiltSendsNothing() async {
        let transport = RecordingTransport()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        // The envelope's counts read waits on the test: reports go off while the report is built.
        let service = service(transport, counts: {
            enteredSignal.yield()
            for await _ in gate { break }
            return .unknown
        })
        await service.setEnabled(true)
        let delivery = Task { await service.receive(HangReportFixtures.metricKitInput()) }
        for await _ in entered { break }
        await service.setEnabled(false)
        open.yield()
        await delivery.value
        #expect(transport.sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: service.lastReportURL.path))
    }

    @Test func turningOffDuringAFlushStopsTheRestOfTheOutbox() async {
        let failing = RecordingTransport([.retryLater, .retryLater])
        let first = service(failing)
        await first.setEnabled(true)
        await first.receive(HangReportFixtures.metricKitInput())
        clock.advance(60)
        await first.receive(HangReportFixtures.metricKitInput())
        let gated = GatedTransport()
        let second = service(gated)
        await second.setEnabled(true)
        let flush = Task { await second.launched() }
        for await _ in gated.started.stream { break }
        await second.setEnabled(false)
        gated.release.continuation.yield()
        gated.release.continuation.finish()
        await flush.value
        #expect(gated.bodies.withLock { $0.count } <= 1)
    }

    @Test func aSettingTurnedOffWhileClosedClearsWhatAnEarlierLaunchLeft() async {
        let first = service(RecordingTransport([.retryLater]))
        await first.setEnabled(true)
        await first.receive(HangReportFixtures.metricKitInput())
        first.collector.noteStall(durationNanos: 600_000_000, cpuNanos: 0, addresses: [1])
        first.saveForNextLaunch()
        #expect(defaults.string(forKey: InstallIdentity.idKey) != nil)
        let second = service(RecordingTransport())
        await second.setEnabled(false)
        #expect(defaults.string(forKey: InstallIdentity.idKey) == nil)
        let transport = RecordingTransport()
        let third = service(transport)
        await third.setEnabled(true)
        await third.launched()
        #expect(transport.sent.isEmpty)
    }

    @Test func aManagedBlockInstalledWhileRunningStopsSendingAndDropsWhatWasRecorded() async {
        let blocked = Mutex(false)
        let transport = RecordingTransport()
        let service = service(transport, allowed: { !blocked.withLock { $0 } })
        await service.setEnabled(true)
        service.collector.noteStall(durationNanos: 400_000_000, cpuNanos: 0, addresses: [1])
        blocked.withLock { $0 = true }
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(transport.sent.isEmpty)
        #expect(defaults.string(forKey: InstallIdentity.idKey) == nil)
        // Allowed again in the same run: nothing recorded while blocked goes out.
        blocked.withLock { $0 = false }
        await service.setEnabled(true)
        await service.launched()
        #expect(transport.sent.isEmpty)
        #expect(service.collector.snapshot().isEmpty)
    }

    @Test func aReportQueuedByAnotherBuildIsDroppedNotSent() async {
        let older = service(RecordingTransport([.retryLater]), build: "70100")
        await older.setEnabled(true)
        await older.receive(HangReportFixtures.metricKitInput())
        let transport = RecordingTransport()
        let newer = service(transport, build: "70123")
        await newer.setEnabled(true)
        await newer.launched()
        #expect(transport.sent.isEmpty)
    }

    /// Schema 1 marks a client without the review 1 and 2 privacy fixes: its queued report is
    /// dropped, even when the build number matches (a re-signed or rebuilt bundle).
    @Test func aQueuedSchemaOneReportIsDroppedNotSent() async throws {
        let failing = RecordingTransport([.retryLater])
        let queuing = service(failing)
        await queuing.setEnabled(true)
        await queuing.receive(HangReportFixtures.metricKitInput())
        let body = try #require(failing.sent.first)
        var old = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(old.schema == HangReport.schemaVersion)
        old.schema = 1
        let store = HangReportStore(directory: directory)
        for entry in await store.outbox(now: clock.now) { await store.remove(entry.url) }
        await store.enqueue(try HangReport.encoder.encode(old), reportId: old.reportId)
        let transport = RecordingTransport()
        let next = service(transport)
        await next.setEnabled(true)
        await next.launched()
        #expect(transport.sent.isEmpty)
        #expect(await store.outbox(now: clock.now).isEmpty)
    }

    @Test func viewBeforeAnySendIsAPreviewThatSendsNothing() async throws {
        let transport = RecordingTransport()
        let service = service(transport)
        let url = try #require(await service.viewableReport())
        #expect(url.lastPathComponent == "preview-report.json")
        #expect(transport.sent.isEmpty)
        _ = try JSONDecoder().decode(HangReport.self, from: Data(contentsOf: url))
    }

    @Test func theInstallIDRotatesAfterThirtyDays() {
        let identity = InstallIdentity(suiteName: suite, now: { [clock] in clock.now })
        let first = identity.current()
        #expect(identity.current() == first)
        clock.advance(29 * 24 * 60 * 60)
        #expect(identity.current() == first)
        clock.advance(2 * 24 * 60 * 60)
        let second = identity.current()
        #expect(second != first)
        #expect(ImageClassifier.isUUID(second))
    }

    @Test func callStackTreesReadTheAttributedThreadsHeaviestPath() {
        let frames = CallStackTreeReader().stack(Data(HangReportFixtures.hangTree.utf8))
        #expect(frames.map(\.offset) == [4_096, 123_456, 777, 55])
        #expect(CallStackTreeReader().stack(Data("[]".utf8)).isEmpty)
        #expect(CallStackTreeReader().stack(Data(HangReportFixtures.cpuTree.utf8)).map(\.offset) == [20, 30])
    }
}
