import AppKit
@testable import CmuxNextTerminal
import CmuxNextCompat
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// FILES QUEUE (Leo's NIGHTLY, 2026-11-21, 25 terminals and 214 chat tabs): the serial `files.bestEffort` lane was busy
/// 66% of a 3 s sample, all in the launch frame keeper's PNG encode (`TerminalLaunchFrames.writeOne` -> `encoded`). Leo:
/// "you can be at 90% cpu and ram and be smooth / or you can be at 50 cpu and ram and starved of threads".
///
/// The keeper's cost on one fixed workload, the same before and after its fix: six terminals of a 1400 x 900 window
/// each, two of them printing 20 lines a second and four switched away and back every 3 s with no new output (a
/// workspace switch), for 21 s. Prints one `KEEP-FRAMES-BENCH {json}` line: the frames encoded, their CPU time, and
/// how long other work on the files lane at the same priority waited meanwhile (a probe job every 100 ms).
/// On demand: `CMUX_KEEP_FRAMES_BENCH=1 swift test --filter TerminalLaunchFrameKeeperBenchTests`.
@MainActor @Suite(.serialized, .closesItsWindows,
                  .enabled(if: ProcessInfo.processInfo.environment["CMUX_KEEP_FRAMES_BENCH"] == "1")) struct TerminalLaunchFrameKeeperBenchTests {
    static let size = NSSize(width: 1400, height: 900)
    static let busy = 2
    static let switched = 4
    static let seconds = 21.0

    @Test func keeperCostOnBusyAndSwitchedTerminals() async throws {
        let work = BackgroundWork(label: "test.terminal-launch-frame-keeper-bench")
        var terminals: [TerminalLaunchFrameKeeperTests.Shown] = []
        defer { terminals.forEach { $0.close() } }
        for _ in 0..<(Self.busy + Self.switched) { terminals.append(try await .init(size: Self.size)) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        let keys = terminals.indices.map { "tab_bench\($0)" }
        for (key, shown) in zip(keys, terminals) { frames.keep(key, session: shown.session, work: work) }
        let allKept = try await TerminalLaunchFrameKeeperTests.eventually(20) {
            keys.allSatisfy { !TerminalLaunchFrameKeeperTests.files($0, in: directory).isEmpty }
        }
        try #require(allKept, "the six terminals' first frames were never kept")
        try await Task.sleep(for: .milliseconds(800)) // test: the first saves' writes end before the measure starts

        let pixels = TerminalLaunchFrameKeeperTests.files(keys[0], in: directory).first.flatMap { name in
            NSImage(contentsOf: directory.appending(path: name))?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
        } ?? "?"
        let saves = frames.keepSaves, lanes = Self.lanes(frames), cpu = Self.processCPU()
        let probe = FilesProbe(work: work)
        let started = ContinuousClock.now, end = started.advanced(by: .seconds(Self.seconds))
        probe.start(until: end)
        var line = 0, tick = 0
        while ContinuousClock.now < end {
            for shown in terminals.prefix(Self.busy) { shown.io.send(.output(Data("busy line \(line)\r\n".utf8))) }
            line += 1
            // Switched away for 1 s of every 3 s, with no new output: shown again, the same frame as before.
            let phase = tick % 60
            if phase == 0 || phase == 20 {
                for shown in terminals.dropFirst(Self.busy) { shown.session.isRenderingSuspended = phase == 0 }
            }
            tick += 1
            try await Task.sleep(for: .milliseconds(50)) // test: the busy programs' line rate and the switch clock
        }
        for shown in terminals.dropFirst(Self.busy) { shown.session.isRenderingSuspended = false }
        let elapsed = Self.ms(ContinuousClock.now - started) / 1000
        let ended = try await probe.finished()
        let minutes = max(elapsed, 1) / 60
        let after = Self.lanes(frames)
        let filesMS = after.files.cpuMilliseconds - lanes.files.cpuMilliseconds
        let cpuMS = after.cpu.cpuMilliseconds - lanes.cpu.cpuMilliseconds
        let encoded = Self.encodes(frames) - lanes.encodes
        let report: [String: Any] = [
            "terminals": terminals.count, "busy": Self.busy, "switched": Self.switched, "seconds": elapsed,
            "frame_px": pixels, "saves": frames.keepSaves - saves, "encodes": encoded,
            "encodes_per_min": Double(encoded) / minutes,
            "files_lane_jobs": after.files.jobs - lanes.files.jobs, "files_lane_cpu_ms_per_min": filesMS / minutes,
            "cpu_lane_cpu_ms_per_min": cpuMS / minutes,
            "process_cpu_ms_per_min": (Self.processCPU() - cpu) / minutes,
            "unchanged": frames.keepWrites.unchanged, "restored": frames.keepWrites.restored,
            "coalesced": frames.keepWrites.coalesced,
            "files_probe_jobs": ended.count, "files_probe_wait_p50_ms": ended.percentile(0.5),
            "files_probe_wait_p95_ms": ended.percentile(0.95), "files_probe_wait_max_ms": ended.max() ?? 0,
        ]
        let json = try JSONSerialization.data(withJSONObject: report)
        print("KEEP-FRAMES-BENCH \(String(decoding: json, as: UTF8.self))")
        #expect(!ended.isEmpty, "the files probe never ran: the lane never drained")
    }

    /// The keeper's lane costs and encodes so far.
    static func lanes(_ frames: TerminalLaunchFrames) -> (files: LaneCost, cpu: LaneCost, encodes: Int) {
        (frames.keepLaneCost.files, frames.keepLaneCost.cpu, encodes(frames))
    }

    static func encodes(_ frames: TerminalLaunchFrames) -> Int { frames.keepWrites.encodes }

    /// The process's user + system CPU time, in ms.
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ms(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    /// Other work on the files lane at the keeper's priority: a job posted every 100 ms records how long it waited to run.
    @MainActor final class FilesProbe {
        nonisolated final class Log: Sendable {
            let waits = Mutex<[Double]>([])
            let drained = Mutex(false)
        }

        let work: BackgroundWork
        private let log = Log()
        private var task: Task<Void, Never>?

        init(work: BackgroundWork) { self.work = work }

        func start(until end: ContinuousClock.Instant) {
            // task-owner: the bench's files-lane probe; ends at `end` (finished() awaits it)
            task = Task { @MainActor [work, log] in
                while ContinuousClock.now < end {
                    let posted = ContinuousClock.now
                    work.post(.bestEffort, mayBlock: .files) {
                        let waited = TerminalLaunchFrameKeeperBenchTests.ms(ContinuousClock.now - posted)
                        log.waits.withLock { $0.append(waited) }
                    }
                    try? await Task.sleep(for: .milliseconds(100)) // test: the probe's rate
                }
            }
        }

        /// The waits, once every probe job ran: one more job after the last marks the lane drained (it is serial per
        /// priority, so every job posted before it has run).
        func finished() async throws -> [Double] {
            await task?.value
            let log = log
            work.post(.bestEffort, mayBlock: .files) { log.drained.withLock { $0 = true } }
            _ = try await TerminalLaunchFrameKeeperTests.eventually(60) { log.drained.withLock { $0 } }
            return log.waits.withLock { $0 }
        }
    }

    nonisolated static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

private extension [Double] {
    func percentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        let sorted = self.sorted()
        return sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
