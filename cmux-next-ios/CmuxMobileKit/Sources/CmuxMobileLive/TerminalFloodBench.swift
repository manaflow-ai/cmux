// DEBUG and Demo builds only: the flood benchmark is never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Darwin
import Foundation
import QuartzCore
import SwiftUI

/// DEBUG only. Launch with `-CmuxMobileFloodBench` to measure the terminal under an
/// output flood through the real pipeline: `DaemonClient` and
/// `DaemonTerminalSession` (JSON lines, base64, the input lane) and the real
/// terminal screen and Ghostty renderer. Only the Mac is faked: a daemon that
/// answers `attach-surface` and `send`, echoes keystrokes, and streams output
/// at a fixed rate in `output` events.
///
/// Options (launch arguments, `-Key value`):
/// - `-CmuxMobileFloodBenchMbps 10`: flood rate in Mbit/s of terminal bytes.
/// - `-CmuxMobileFloodBenchChunk 4096`: bytes per `output` event.
/// - `-CmuxMobileFloodBenchFile /path`: recorded PTY output to replay (looped);
///   default: generated 999-column lines like `verify/terminal-input-lane.md`'s flood.
/// - `-CmuxMobileFloodBenchMode topline`: instead, rewrite the top row 100 times a second.
/// - `-CmuxMobileFloodBenchSeconds 10`: flood length.
///
/// Phases: 3 s idle, the flood, 6 s after it. Each second it logs the main
/// thread's CPU time (thread_info) and the whole app's (getrusage), main-queue latency (a ping from a
/// background thread every 10 ms, a proxy for touch delivery), keystroke
/// echo latency (keystroke on a background timer every 200 ms → first frame
/// presented after Ghostty processed its echo), frames presented and the
/// bytes Ghostty processed. The summary goes to `Documents/flood-bench.json`
/// and the log (`[flood-bench]`).
public struct TerminalFloodBenchRoot: View {
    @State private var bench = TerminalFloodBench()

    public init() {}

    public static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileFloodBench") }

    public var body: some View {
        NavigationStack {
            TerminalScreen(model: bench.model)
        }
        .task { await bench.run() }
    }
}

@MainActor
final class TerminalFloodBench {
    let model: TerminalModel
    private let daemon: FloodDaemon
    private let probe = TerminalBenchProbe()
    private let sampler = MainThreadSampler()

    init() {
        let defaults = UserDefaults.standard
        let mbps = defaults.double(forKey: "CmuxMobileFloodBenchMbps")
        let chunk = defaults.integer(forKey: "CmuxMobileFloodBenchChunk")
        let file = defaults.string(forKey: "CmuxMobileFloodBenchFile")
        let topline = defaults.string(forKey: "CmuxMobileFloodBenchMode") == "topline"
        let corpus = file.flatMap { FileManager.default.contents(atPath: $0) } ?? FloodDaemon.generatedCorpus()
        daemon = FloodDaemon(
            corpus: corpus,
            bytesPerSecond: (mbps > 0 ? mbps : 10) * 1_000_000 / 8,
            chunk: chunk > 0 ? chunk : 4096,
            topline: topline
        )
        daemon.probe = probe
        let daemon = daemon
        let session = DaemonTerminalSession(
            surface: 1,
            open: { DaemonClient(channel: daemon.main) },
            openInput: { DaemonClient(channel: daemon.lane) }
        )
        model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "flood bench")
    }

    private func log(_ text: String) {
        NSLog("[flood-bench] %@", text)
    }

    func run() async {
        // Claimed here, not in init: SwiftUI evaluates `@State`'s initial value
        // on every rebuild of the root view and drops the extra instances, and
        // each one's init took the shared probe away from the bench that runs
        // (fleet runs, 2026-10-26: 0 bytes processed, 0 frames, no echo seen).
        TerminalBenchProbe.shared = probe
        let clock = ContinuousClock()
        let seconds = UserDefaults.standard.integer(forKey: "CmuxMobileFloodBenchSeconds")
        let floodSeconds = seconds > 0 ? seconds : 10
        // Wait for the attach and the first frames.
        while !model.connectionState.isAttached { try? await clock.sleep(for: .milliseconds(50)) }
        try? await clock.sleep(for: .seconds(2))
        sampler.start()
        let keys = KeystrokeTimer(probe: probe) { [weak self] in
            guard let self else { return }
            self.model.composerText = "k"
            self.model.sendWithoutReturn()
        }
        keys.start()
        var rows: [[String: Any]] = []
        var phases: [String: [[String: Any]]] = [:]
        _ = probe.take()
        var last = probe.take()
        var lastProcessCPU = processCPUSeconds()
        func second(_ phase: String, _ index: Int) async {
            try? await clock.sleep(for: .seconds(1))
            let now = probe.take()
            let main = sampler.take()
            let processCPU = processCPUSeconds()
            defer { lastProcessCPU = processCPU }
            var row: [String: Any] = [
                "phase": phase, "t": index,
                "mainCPUms": (main.cpuMs * 10).rounded() / 10,
                "processCPUms": ((processCPU - lastProcessCPU) * 10_000).rounded() / 10,
                "pingP50ms": main.ping.percentile(0.5), "pingP99ms": main.ping.percentile(0.99), "pingMaxms": main.ping.max() ?? 0,
                "presents": now.presents - last.presents,
                "processedKB": (now.processed - last.processed) / 1024,
                "emittedKB": daemon.emittedTotal / 1024,
                "echoes": now.echoLatencies.count,
                "pendingEchoes": now.pendingEchoes,
            ]
            if !now.echoLatencies.isEmpty {
                row["echoP50ms"] = now.echoLatencies.percentile(0.5)
                row["echoMaxms"] = now.echoLatencies.max() ?? 0
            }
            row["echoLatencies"] = now.echoLatencies.map { ($0 * 10).rounded() / 10 }
            row["pings"] = main.ping.map { ($0 * 10).rounded() / 10 }
            row["frameIntervals"] = now.frameIntervals.map { ($0 * 10).rounded() / 10 }
            last = now
            rows.append(row)
            phases[phase, default: []].append(row)
            log("\(phase) t=\(index) mainCPU=\(row["mainCPUms"]!)ms ping p50/p99/max=\(row["pingP50ms"]!)/\(row["pingP99ms"]!)/\(row["pingMaxms"]!) presents=\(row["presents"]!) processedKB=\(row["processedKB"]!) echoes=\(now.echoLatencies.count) echo p50/max=\(row["echoP50ms"] ?? "-")/\(row["echoMaxms"] ?? "-") pending=\(now.pendingEchoes)")
        }
        for index in 0..<3 { await second("idle", index) }
        let floodStart = clock.now
        daemon.startFlood()
        for index in 0..<floodSeconds { await second("flood", index) }
        daemon.stopFlood()
        // Drain: from the stop until Ghostty processed every byte the daemon
        // had sent by then (+ the session's reset), timed by the probe as the
        // bytes are parsed. Echoes typed after the stop do not move the target.
        probe.timeDrain(until: daemon.emittedTotal + 2, since: CACurrentMediaTime())
        for index in 0..<6 { await second("after", index) }
        let drainMs = probe.take().drainMs.map { ($0 * 10).rounded() / 10 }
        keys.stop()
        sampler.stop()
        let flood = phases["flood"] ?? []
        func all(_ key: String, _ rows: [[String: Any]]) -> [Double] { rows.flatMap { ($0[key] as? [Double]) ?? [] } }
        func avg(_ key: String, _ rows: [[String: Any]]) -> Double {
            let values = rows.compactMap { $0[key] as? Double }
            return values.isEmpty ? 0 : (values.reduce(0, +) / Double(values.count) * 10).rounded() / 10
        }
        var summary: [String: Any] = [
            "rateMbps": daemon.bytesPerSecond * 8 / 1_000_000,
            "chunk": daemon.chunk,
            "mode": daemon.topline ? "topline" : "rate",
            "floodSeconds": (clock.now - floodStart).components.seconds,
            "emittedKB": daemon.emittedTotal / 1024,
            "drainAfterStopMs": drainMs ?? -1,
        ]
        for phase in ["idle", "flood", "after"] {
            let rows = phases[phase] ?? []
            let pings = all("pings", rows)
            let echoes = all("echoLatencies", rows)
            let frames = all("frameIntervals", rows)
            summary[phase] = [
                "mainCPUmsPerSecondAvg": avg("mainCPUms", rows),
                "mainCPUmsPerSecondMax": rows.compactMap { $0["mainCPUms"] as? Double }.max() ?? 0,
                "processCPUmsPerSecondAvg": avg("processCPUms", rows),
                "processCPUmsPerSecondMax": rows.compactMap { $0["processCPUms"] as? Double }.max() ?? 0,
                "frameIntervalP50ms": frames.percentile(0.5), "frameIntervalP95ms": frames.percentile(0.95),
                "frameIntervalMaxms": frames.max() ?? 0,
                "pingP50ms": pings.percentile(0.5), "pingP99ms": pings.percentile(0.99), "pingMaxms": pings.max() ?? 0,
                "echoCount": echoes.count, "echoP50ms": echoes.percentile(0.5), "echoP90ms": echoes.percentile(0.9), "echoMaxms": echoes.max() ?? 0,
                "presentsPerSecondAvg": rows.isEmpty ? 0 : Double(rows.compactMap { $0["presents"] as? Int }.reduce(0, +)) / Double(rows.count),
                "processedKBPerSecondAvg": rows.isEmpty ? 0 : Double(rows.compactMap { $0["processedKB"] as? Int }.reduce(0, +)) / Double(rows.count),
            ] as [String: Any]
        }
        summary["pendingEchoesAtEnd"] = probe.take().pendingEchoes
        _ = flood
        log("summary \(summary)")
        let report: [String: Any] = ["summary": summary, "seconds": rows]
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("flood-bench.json"))
        }
        log("done")
    }
}

/// CPU time of every thread of the app (getrusage), the renderer and Ghostty's IO threads included.
private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

extension Array where Element == Double {
    func percentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        let sorted = self.sorted()
        let value = sorted[Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        return (value * 10).rounded() / 10
    }
}

/// Keystrokes on a background timer (like touches, they wait for the main thread).
private final class KeystrokeTimer: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    init(probe: TerminalBenchProbe, type: @escaping @MainActor () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "flood-bench.keys"))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(200))
        timer.setEventHandler {
            probe.keystroke(at: CACurrentMediaTime())
            DispatchQueue.main.async { MainActor.assumeIsolated { type() } }
        }
    }
    func start() { timer.resume() }
    func stop() { timer.cancel() }
}

/// The main thread's CPU time (thread_info) and main-queue latency.
private final class MainThreadSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var pings: [Double] = []
    private var thread: thread_act_t = 0
    private var lastCPU: Double = 0
    private var timer: DispatchSourceTimer?

    @MainActor func start() {
        thread = mach_thread_self()
        lastCPU = cpuSeconds()
        startPings()
    }

    /// Nonisolated: the timer's handler runs on its own queue.
    private nonisolated func startPings() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "flood-bench.ping"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            let sent = CACurrentMediaTime()
            DispatchQueue.main.async {
                let latency = (CACurrentMediaTime() - sent) * 1000
                self?.lock.withLock { self?.pings.append(latency) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel() }

    private func cpuSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    /// Main-thread CPU ms since the last call, and the pings since then.
    func take() -> (cpuMs: Double, ping: [Double]) {
        let cpu = cpuSeconds()
        defer { lastCPU = cpu }
        let taken = lock.withLock { () -> [Double] in defer { pings.removeAll() }; return pings }
        return ((cpu - lastCPU) * 1000, taken)
    }
}

/// The fake Mac: a cmux-tui daemon for surface 1 on two channels (attach and
/// input lane). Output events go out on the attach channel at a fixed byte
/// rate; each `send` is echoed there, behind the output already queued, as a
/// real PTY's echo would be.
final class FloodDaemon: @unchecked Sendable {
    let corpus: Data
    let bytesPerSecond: Double
    let chunk: Int
    let topline: Bool
    var probe: TerminalBenchProbe?
    let main: FloodChannel
    let lane: FloodChannel
    private let lock = NSLock()
    private var emitted = 0
    private var corpusOffset = 0
    private var flooding = false
    private var timer: DispatchSourceTimer?
    private var floodStart: CFTimeInterval = 0
    private var floodEmitted = 0
    private var topTick = 0

    var emittedTotal: Int { lock.withLock { emitted } }

    init(corpus: Data, bytesPerSecond: Double, chunk: Int, topline: Bool) {
        self.corpus = corpus.isEmpty ? FloodDaemon.generatedCorpus() : corpus
        self.bytesPerSecond = bytesPerSecond
        self.chunk = chunk
        self.topline = topline
        main = FloodChannel(id: 1)
        lane = FloodChannel(id: 2)
        main.onSend = { [weak self] line in self?.request(line, on: self?.main) }
        lane.onSend = { [weak self] line in self?.request(line, on: self?.lane) }
    }

    /// 999-column lines (the input-lane flood) and a colored build log.
    static func generatedCorpus() -> Data {
        var text = ""
        for index in 0..<400 {
            if index % 4 == 0 {
                text += "\u{1B}[1;32m   Compiling\u{1B}[0m cmux-mobile-crate-\(index) v0.\(index % 9).\(index % 7) (/Users/dev/src/mobile/crates/cmux-mobile-crate-\(index))\r\n"
            } else {
                text += String(repeating: "y", count: 999) + "\r\n"
            }
        }
        return Data(text.utf8)
    }

    private func output(_ data: Data) -> Data { outputEvent(data).line }

    /// An output event line, and the session byte offset its bytes end at.
    private func outputEvent(_ data: Data) -> (line: Data, end: Int) {
        let end = lock.withLock { emitted += data.count; return emitted + 2 } // + the session's reset (ESC c)
        var line = try! JSONSerialization.data(withJSONObject: ["event": "output", "surface": 1, "data": data.base64EncodedString()], options: [.sortedKeys])
        line.append(0x0A)
        return (line, end)
    }

    private func request(_ line: Data, on channel: FloodChannel?) {
        guard let channel, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return }
        func reply() -> Data {
            var data = try! JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": [String: Any]()], options: [.sortedKeys])
            data.append(0x0A)
            return data
        }
        switch cmd {
        case "attach-surface":
            var state = try! JSONSerialization.data(withJSONObject: [
                "event": "vt-state", "surface": 1, "cols": 80, "rows": 40,
                "data": Data("flood bench\r\n$ ".utf8).base64EncodedString(),
            ], options: [.sortedKeys])
            state.append(0x0A)
            lock.withLock { emitted += "flood bench\r\n$ ".utf8.count }
            channel.push([state, reply()])
        case "send":
            channel.push([reply()])
            if let bytes = (object["bytes"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                // The echo, behind the output already queued on the attach channel.
                let (echoLine, end) = outputEvent(bytes)
                probe?.echo(count: bytes.count, endingAt: end)
                main.push([echoLine])
            }
        default:
            channel.push([reply()])
        }
    }

    func startFlood() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "flood-bench.daemon", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(topline ? 10 : 2))
        floodStart = CACurrentMediaTime()
        floodEmitted = 0
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { flooding = true }
        timer.resume()
        self.timer = timer
    }

    func stopFlood() {
        lock.withLock { flooding = false }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard lock.withLock({ flooding }) else { return }
        if topline {
            // `printf '\e[H...'` 100 times a second: the top row rewritten in place.
            topTick += 1
            let text = "\u{1B}7\u{1B}[1;1H\u{1B}[2K\u{1B}[7m tick \(topTick) \(CACurrentMediaTime()) \u{1B}[0m\u{1B}8"
            main.push([output(Data(text.utf8))])
            return
        }
        let due = Int((CACurrentMediaTime() - floodStart) * bytesPerSecond) - floodEmitted
        var lines: [Data] = []
        var remaining = due
        while remaining >= chunk {
            var piece = Data()
            while piece.count < chunk {
                let take = min(chunk - piece.count, corpus.count - corpusOffset)
                piece.append(corpus[corpus.startIndex + corpusOffset ..< corpus.startIndex + corpusOffset + take])
                corpusOffset = (corpusOffset + take) % corpus.count
            }
            lines.append(output(piece))
            floodEmitted += chunk
            remaining -= chunk
        }
        if !lines.isEmpty { main.push(lines) }
    }
}

/// An in-memory link channel: lines the app sends go to `onSend`; lines
/// pushed by the fake daemon come back from `receive`, one link frame each.
final class FloodChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32
    var onSend: ((Data) -> Void)?
    private let lock = NSLock()
    private var queue: [Data] = []
    private var head = 0
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var closed = false
    private var sendBuffer = Data()

    init(id: UInt32) { self.id = id }

    func send(_ data: Data) async throws {
        let lines: [Data] = lock.withLock {
            sendBuffer.append(data)
            var lines: [Data] = []
            while let newline = sendBuffer.firstIndex(of: 0x0A) {
                lines.append(Data(sendBuffer[sendBuffer.startIndex..<newline]))
                sendBuffer.removeSubrange(sendBuffer.startIndex...newline)
            }
            return lines
        }
        for line in lines { onSend?(line) }
    }

    func push(_ lines: [Data]) {
        let resume: (CheckedContinuation<Data?, any Error>, Data)? = lock.withLock {
            queue.append(contentsOf: lines)
            guard let waiter, head < queue.count else { return nil }
            self.waiter = nil
            let next = queue[head]
            head += 1
            compact()
            return (waiter, next)
        }
        if let (waiter, data) = resume { waiter.resume(returning: data) }
    }

    private func compact() {
        if head > 4096 {
            queue.removeFirst(head)
            head = 0
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Data?? = lock.withLock {
                if head < queue.count {
                    let next = queue[head]
                    head += 1
                    compact()
                    return .some(next)
                }
                if closed { return .some(nil) }
                waiter = continuation
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func close(code: String, reason: String) async {
        let waiter: CheckedContinuation<Data?, any Error>? = lock.withLock {
            closed = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: nil)
    }
}
#endif
