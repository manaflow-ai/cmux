import Foundation
import Testing

@testable import CmuxSocketObservability

/// Records watchdog callbacks for deterministic state-machine assertions.
///
/// Safety: mutable records are protected by `lock`.
private final class RecordingWatchdogReporter: MainThreadSocketCommandWatchdogReporter, @unchecked Sendable {
    struct Hang: Equatable {
        let elapsedMs: Double
        let method: String
        let backtrace: [String]
    }

    struct Recovery: Equatable {
        let elapsedMs: Double
        let method: String
    }

    // Protects records captured from a Sendable reporter during synchronous tests.
    private let lock = NSLock()
    private var _hangs: [Hang] = []
    private var _recoveries: [Recovery] = []
    let hangSignal = DispatchSemaphore(value: 0)
    let recoverySignal = DispatchSemaphore(value: 0)

    var hangs: [Hang] {
        lock.lock()
        defer { lock.unlock() }
        return _hangs
    }

    var recoveries: [Recovery] {
        lock.lock()
        defer { lock.unlock() }
        return _recoveries
    }

    func reportHang(_ observation: MainThreadSocketCommandWatchdogObservation) {
        lock.lock()
        _hangs.append(.init(
            elapsedMs: observation.elapsedMs,
            method: observation.descriptor.method,
            backtrace: observation.backtrace
        ))
        lock.unlock()
        hangSignal.signal()
    }

    func reportRecovery(_ observation: MainThreadSocketCommandWatchdogObservation) {
        lock.lock()
        _recoveries.append(.init(
            elapsedMs: observation.elapsedMs,
            method: observation.descriptor.method
        ))
        lock.unlock()
        recoverySignal.signal()
    }
}

/// Fixed backtrace provider so watchdog tests do not inspect process symbols.
private struct FixedBacktraceCapturer: SocketCommandBacktraceCapturing {
    let frames: [String]

    func captureBacktrace() -> [String] {
        frames
    }
}

private final class BlockingBacktraceCapturer: SocketCommandBacktraceCapturing, @unchecked Sendable {
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)

    func captureBacktrace() -> [String] {
        started.continuation.yield(())
        started.continuation.finish()
        release.wait()
        return ["late"]
    }
}

@Suite
struct MainThreadWatchdogTests {
    @Test
    func realDeadlineReportsHangAndRecoveryWithoutCooperativeExecutor() {
        let reporter = RecordingWatchdogReporter()
        let watchdog = MainThreadSocketCommandWatchdog(
            thresholdMs: 10,
            reporter: reporter,
            backtraceCapturer: FixedBacktraceCapturer(frames: ["real-deadline"])
        )
        let response = watchdog.monitor(
            descriptor: descriptor(),
            startNs: DispatchTime.now().uptimeNanoseconds
        ) {
            #expect(reporter.hangSignal.wait(timeout: .now() + 5) == .success)
            return "response"
        }
        #expect(response == "response")
        #expect(reporter.recoverySignal.wait(timeout: .now() + 5) == .success)
        #expect(reporter.hangs.count == 1)
        #expect(reporter.recoveries.count == 1)
        #expect(reporter.hangs.first?.backtrace == ["real-deadline"])
    }

    @Test
    func workerLaneDoesNotArmWatchdog() {
        let reporter = RecordingWatchdogReporter()
        let watchdog = MainThreadSocketCommandWatchdog(
            thresholdMs: 1,
            reporter: reporter,
            backtraceCapturer: FixedBacktraceCapturer(frames: [])
        )
        let response = watchdog.monitor(
            descriptor: SocketCommandDescriptor(protocolName: "v2", method: "browser.eval", executedOnMain: false, peerPid: nil),
            startNs: 0
        ) { "response" }
        #expect(response == "response")
        #expect(reporter.hangs.isEmpty)
        #expect(reporter.recoveries.isEmpty)
    }

    private let ms: UInt64 = 1_000_000

    private func descriptor(method: String = "browser.eval") -> SocketCommandDescriptor {
        SocketCommandDescriptor(
            protocolName: "v2",
            method: method,
            executedOnMain: true,
            peerPid: 4242
        )
    }

    private func makeTicket(
        reporter: RecordingWatchdogReporter,
        thresholdMs: Double = 1000,
        backtrace: [String] = ["frame-0", "frame-1"]
    ) -> MainThreadSocketCommandWatchdogTicket {
        MainThreadSocketCommandWatchdogTicket(
            descriptor: descriptor(),
            thresholdMs: thresholdMs,
            startNs: 0,
            reporter: reporter,
            backtraceCapturer: FixedBacktraceCapturer(frames: backtrace)
        )
    }

    @Test
    func noHangReportedBelowThreshold() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.fireIfNeeded(nowNs: 999 * ms)

        #expect(reporter.hangs.isEmpty)
        #expect(reporter.recoveries.isEmpty)
    }

    @Test
    func hangIncludesCommandIdentityAndBacktraceAtThreshold() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter, backtrace: ["watchdog", "dispatch"])

        ticket.fireIfNeeded(nowNs: 1000 * ms)

        #expect(reporter.hangs.count == 1)
        #expect(reporter.hangs[0].method == "browser.eval")
        #expect(reporter.hangs[0].elapsedMs == 1000)
        #expect(reporter.hangs[0].backtrace == ["watchdog", "dispatch"])
    }

    @Test
    func sustainedHangReportsOnlyOnceForCommand() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.fireIfNeeded(nowNs: 1000 * ms)
        ticket.fireIfNeeded(nowNs: 2000 * ms)
        ticket.fireIfNeeded(nowNs: 4000 * ms)

        #expect(reporter.hangs.count == 1)
        #expect(reporter.recoveries.isEmpty)
    }

    @Test
    func recoveryReportedOnceAfterHangCompletes() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.fireIfNeeded(nowNs: 1000 * ms)
        ticket.finish(nowNs: 2500 * ms)
        ticket.finish(nowNs: 3000 * ms)

        #expect(reporter.hangs.count == 1)
        #expect(reporter.recoveries.count == 1)
        #expect(reporter.recoveries[0].method == "browser.eval")
        #expect(reporter.recoveries[0].elapsedMs == 2500)
    }

    @Test
    func finishingBeforeThresholdPreventsLaterHang() {
        let reporter = RecordingWatchdogReporter()
        let ticket = makeTicket(reporter: reporter)

        ticket.finish(nowNs: 250 * ms)
        ticket.fireIfNeeded(nowNs: 2000 * ms)

        #expect(reporter.hangs.isEmpty)
        #expect(reporter.recoveries.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func finishingDuringBacktraceCaptureDoesNotReportLateHang() async {
        let reporter = RecordingWatchdogReporter()
        let capturer = BlockingBacktraceCapturer()
        let ticket = MainThreadSocketCommandWatchdogTicket(
            descriptor: descriptor(),
            thresholdMs: 1000,
            startNs: 0,
            reporter: reporter,
            backtraceCapturer: capturer
        )
        let thresholdNs = 1000 * ms

        let finished = AsyncStream<Void>.makeStream()
        Thread.detachNewThread {
            ticket.fireIfNeeded(nowNs: thresholdNs)
            finished.continuation.yield(())
            finished.continuation.finish()
        }

        var startedIterator = capturer.started.stream.makeAsyncIterator()
        await startedIterator.next()
        ticket.finish(nowNs: 1500 * ms)
        capturer.release.signal()
        var finishedIterator = finished.stream.makeAsyncIterator()
        await finishedIterator.next()

        #expect(reporter.hangs.isEmpty)
        #expect(reporter.recoveries.isEmpty)
    }
}
