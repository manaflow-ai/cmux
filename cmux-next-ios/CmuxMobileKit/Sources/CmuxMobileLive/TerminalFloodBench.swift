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
/// - `-CmuxMobileFloodBenchMode agent`: instead, an agent CLI's screen the way Claude Code
///   (Ink) draws it: its live area (spinner, the streaming reply, the input box) erased and
///   redrawn 30 times a second, a finished paragraph committed above it every 1.5 s, and each
///   keystroke echoed as a redraw of the live area with the typed text in the box. Keys go
///   through the native keyboard path (`insertText`, as the software keyboard calls it), 8 a
///   second, and each key's main-thread time is measured.
/// - `-CmuxMobileFloodBenchLiveRows 24`: rows of the agent's live area.
/// - `-CmuxMobileFloodBenchNoFocus`: the agent workload types without giving the terminal the
///   keyboard (no software keyboard, no input delegate).
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
        .overlay(alignment: .top) {
            // Only once the bench is done: the UI test (TerminalTypingWhileStreamingUITests) waits for it.
            if !bench.result.isEmpty {
                Text(bench.result)
                    .lineLimit(2)
                    .accessibilityIdentifier("flood-bench.result")
                    .accessibilityLabel(bench.result)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
        }
        .task { await bench.run() }
    }
}

@MainActor @Observable
final class TerminalFloodBench {
    /// The summary as one line of JSON, once the run is done (the result label's text).
    private(set) var result = ""
    let model: TerminalModel
    private let daemon: FloodDaemon
    private let probe = TerminalBenchProbe()
    private let sampler = MainThreadSampler()
    /// The agent CLI workload (`-CmuxMobileFloodBenchMode agent`): native-path keys.
    private let agent: Bool
    /// Main-thread milliseconds of each native-path keystroke since the last second's row.
    private var keyMainMs: [Double] = []
    private var keyIndex = 0

    init() {
        let defaults = UserDefaults.standard
        let mbps = defaults.double(forKey: "CmuxMobileFloodBenchMbps")
        let chunk = defaults.integer(forKey: "CmuxMobileFloodBenchChunk")
        let file = defaults.string(forKey: "CmuxMobileFloodBenchFile")
        let mode = defaults.string(forKey: "CmuxMobileFloodBenchMode")
        let topline = mode == "topline"
        let isAgent = mode == "agent"
        agent = isAgent
        let liveRows = defaults.integer(forKey: "CmuxMobileFloodBenchLiveRows")
        let corpus = file.flatMap { FileManager.default.contents(atPath: $0) } ?? FloodDaemon.generatedCorpus()
        daemon = FloodDaemon(
            corpus: corpus,
            bytesPerSecond: (mbps > 0 ? mbps : 10) * 1_000_000 / 8,
            chunk: chunk > 0 ? chunk : 4096,
            topline: topline,
            agentLiveRows: isAgent ? (liveRows > 0 ? liveRows : 24) : 0
        )
        daemon.probe = probe
        let daemon = daemon
        let session = DaemonTerminalSession(
            surface: 1,
            open: { DaemonClient(channel: daemon.main, eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) },
            openInput: { DaemonClient(channel: daemon.lane, eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) }
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
        // The agent workload types into the terminal itself: it takes the keyboard first, and the
        // keyboard's animation ends in the settle below.
        let focuses = agent && !CommandLine.arguments.contains("-CmuxMobileFloodBenchNoFocus")
        if focuses { model.benchFocusTerminal() }
        try? await clock.sleep(for: .seconds(2))
        sampler.start()
        let keys = KeystrokeTimer(probe: probe, every: agent ? .milliseconds(125) : .milliseconds(200)) { [weak self] in
            guard let self else { return }
            guard self.agent else {
                self.model.composerText = "k"
                self.model.sendWithoutReturn()
                return
            }
            // A person typing a prompt: letters, a space now and then.
            let letters = Array("the quick brown fox jumps over the lazy dog ")
            let key = String(letters[self.keyIndex % letters.count])
            self.keyIndex += 1
            if let ms = self.model.benchTypeNativeKey(key) { self.keyMainMs.append(ms) }
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
            let keyMs = keyMainMs
            keyMainMs.removeAll()
            row["keyMainMs"] = keyMs.map { ($0 * 100).rounded() / 100 }
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
            "mode": agent ? "agent" : daemon.topline ? "topline" : "rate",
            "floodSeconds": (clock.now - floodStart).components.seconds,
            "emittedKB": daemon.emittedTotal / 1024,
            "drainAfterStopMs": drainMs ?? -1,
        ]
        for phase in ["idle", "flood", "after"] {
            let rows = phases[phase] ?? []
            let pings = all("pings", rows)
            let echoes = all("echoLatencies", rows)
            let frames = all("frameIntervals", rows)
            let keyMs = all("keyMainMs", rows)
            summary[phase] = [
                "mainCPUmsPerSecondAvg": avg("mainCPUms", rows),
                "mainCPUmsPerSecondMax": rows.compactMap { $0["mainCPUms"] as? Double }.max() ?? 0,
                "processCPUmsPerSecondAvg": avg("processCPUms", rows),
                "processCPUmsPerSecondMax": rows.compactMap { $0["processCPUms"] as? Double }.max() ?? 0,
                "frameIntervalP50ms": frames.percentile(0.5), "frameIntervalP95ms": frames.percentile(0.95),
                "frameIntervalMaxms": frames.max() ?? 0,
                "pingP50ms": pings.percentile(0.5), "pingP99ms": pings.percentile(0.99), "pingMaxms": pings.max() ?? 0,
                "keyCount": keyMs.count, "keyMainP50ms": keyMs.percentile(0.5), "keyMainP95ms": keyMs.percentile(0.95),  // gitleaks:allow (metric names, not a key)
                "keyMainMaxms": keyMs.max() ?? 0,
                "echoCount": echoes.count, "echoP50ms": echoes.percentile(0.5), "echoP90ms": echoes.percentile(0.9), "echoMaxms": echoes.max() ?? 0,
                "presentsPerSecondAvg": rows.isEmpty ? 0 : Double(rows.compactMap { $0["presents"] as? Int }.reduce(0, +)) / Double(rows.count),
                "processedKBPerSecondAvg": rows.isEmpty ? 0 : Double(rows.compactMap { $0["processedKB"] as? Int }.reduce(0, +)) / Double(rows.count),
            ] as [String: Any]
        }
        summary["pendingEchoesAtEnd"] = probe.take().pendingEchoes
        summary["focused"] = focuses
        summary["frameLog"] = CommandLine.arguments.contains("-CmuxMobileFrameLog")
        summary["channels"] = ["main": daemon.main.counts(), "lane": daemon.lane.counts()]
        summary["connection"] = String(describing: model.connectionState)
        if let frames = Self.streamingFrameStats() { summary["streamingFrames"] = frames }
        _ = flood
        log("summary \(summary)")
        let report: [String: Any] = ["summary": summary, "seconds": rows]
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: documents.appendingPathComponent("flood-bench.json"))
        }
        result = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"summary\"}"
        log("done")
    }

    /// The terminal's frame log (`-CmuxMobileFrameLog`, `Documents/frame-log.ndjson`) over the
    /// frames output streamed in: display-link intervals, hitches (over 1.5 frames) and the
    /// screen's main-thread work per frame, with each signpost's share. Nil without a log.
    private static func streamingFrameStats() -> [String: Any]? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let text = try? String(contentsOf: documents.appendingPathComponent("frame-log.ndjson"), encoding: .utf8) else { return nil }
        var intervals: [Double] = []
        var work: [Double] = []
        var targets: [Double] = []
        var parts: [String: [Double]] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["streaming"] as? Bool == true, let dt = object["dt_ms"] as? Double else { continue }
            intervals.append(dt)
            work.append(object["work_ms"] as? Double ?? 0)
            targets.append(object["target_ms"] as? Double ?? 0)
            for (name, ms) in object["parts"] as? [String: Double] ?? [:] { parts[name, default: []].append(ms) }
        }
        guard !intervals.isEmpty else { return nil }
        let frame = targets.percentile(0.5) > 0 ? targets.percentile(0.5) : 1000.0 / 120
        return [
            "frames": intervals.count,
            "intervalP50ms": intervals.percentile(0.5), "intervalP95ms": intervals.percentile(0.95), "intervalMaxms": intervals.max() ?? 0,
            "hitches": intervals.filter { $0 > frame * 1.5 }.count,
            "workP50ms": work.percentile(0.5), "workP95ms": work.percentile(0.95), "workMaxms": work.max() ?? 0,
            "parts": parts.mapValues { ["frames": $0.count, "totalMs": ($0.reduce(0, +) * 10).rounded() / 10, "p95ms": $0.percentile(0.95),
                                        "maxMs": (($0.max() ?? 0) * 10).rounded() / 10] as [String: Any] },
        ]
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
    init(probe: TerminalBenchProbe, every interval: DispatchTimeInterval, type: @escaping @MainActor () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "flood-bench.keys"))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: interval)
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
    /// Rows of the agent CLI's live area (0: not the agent workload).
    let agentLiveRows: Int
    private let agentLock = NSLock()
    private var agentScreen = AgentScreen()
    /// The fake PTY's grid, columns and rows (agent workload).
    private var agentGridNow: [Int] = [80, 40]

    var emittedTotal: Int { lock.withLock { emitted } }

    init(corpus: Data, bytesPerSecond: Double, chunk: Int, topline: Bool, agentLiveRows: Int = 0) {
        self.agentLiveRows = agentLiveRows
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
            // The agent workload answers like a Mac that takes the phone's size (a pane the phone
            // sized, or Fit to Phone): its grid is the one the attach asks for. A grid the phone did
            // not ask for is held until the claim brings its own back (TerminalReclaimHold), and the
            // fake never brings it back, so the agent's output would wait there for the whole run.
            let agentGrid = agentLiveRows > 0 ? (object["cols"] as? Int).flatMap { cols in (object["rows"] as? Int).map { (cols, $0) } } : nil
            agentLock.withLock { agentGridNow = agentGrid.map { [$0.0, $0.1] } ?? [80, 40] }
            var state = try! JSONSerialization.data(withJSONObject: [
                "event": "vt-state", "surface": 1, "cols": agentGrid?.0 ?? 80, "rows": agentGrid?.1 ?? 40,
                "data": Data("flood bench\r\n$ ".utf8).base64EncodedString(),
            ], options: [.sortedKeys])
            state.append(0x0A)
            lock.withLock { emitted += "flood bench\r\n$ ".utf8.count }
            channel.push([state, reply()])
        case "resize-surface" where agentLiveRows > 0:
            // The phone's size claim: the Mac's PTY takes it and replays its screen at that grid.
            channel.push([reply()])
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int else { break }
            agentLock.withLock {
                // The lease refresh claims the same size again: the PTY does not resize.
                guard agentGridNow != [cols, rows] else { return }
                agentGridNow = [cols, rows]
                agentScreen.forgetDrawn()
                let replay = Data(agentScreen.redraw(rows: agentLiveRows).utf8)
                lock.withLock { emitted += replay.count + 2 }
                guard var resized = try? JSONSerialization.data(withJSONObject: [
                    "event": "resized", "surface": 1, "cols": cols, "rows": rows, "replay": replay.base64EncodedString(),
                ], options: [.sortedKeys]) else { return }
                resized.append(0x0A)
                main.push([resized])
            }
        case "send":
            channel.push([reply()])
            if agentLiveRows > 0, let bytes = (object["bytes"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                // An agent CLI echoes a key by redrawing its live area with the key in its box.
                agentLock.withLock {
                    agentScreen.type(bytes)
                    let (echoLine, end) = outputEvent(Data(agentScreen.redraw(rows: agentLiveRows).utf8))
                    probe?.echo(count: bytes.count, endingAt: end)
                    main.push([echoLine])
                }
            } else if let bytes = (object["bytes"] as? String).flatMap({ Data(base64Encoded: $0) }) {
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
        timer.schedule(deadline: .now(), repeating: .milliseconds(agentLiveRows > 0 ? 33 : topline ? 10 : 2))
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
        if agentLiveRows > 0 {
            agentLock.withLock {
                agentScreen.advance()
                main.push([output(Data(agentScreen.redraw(rows: agentLiveRows).utf8))])
            }
            return
        }
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

/// The screen of an agent CLI drawn the way Claude Code's renderer (Ink's log-update) draws
/// it: each render erases the rows it wrote last time (`ESC [2K` and `ESC [1A` per row) and
/// writes the live area again: a spinner, the reply streaming in, the input box with what
/// was typed, a hint row. A finished paragraph is written once above the live area, where
/// it scrolls up with the rest of the transcript.
struct AgentScreen {
    private var typed = ""
    private var reply: [String] = []
    private var tick = 0
    private var paragraph = 0
    /// Rows the last render wrote (its trailing newline included).
    private var drawn = 0
    /// Rows the cursor was left above the end of the last render (it waits in the input box,
    /// as Claude Code's does, with the box's bottom edge and the hint row below it).
    private var parkedAbove = 0
    private static let words = ("Looking at `TerminalSurfaceView.swift`, the keystroke path runs **insertText** on the main "
        + "thread and hands the bytes to the session. The reply streams while you type, so every frame redraws "
        + "the live area: the spinner, these lines and the input box below. Next I'll read `pumpOutput` and the "
        + "present handler to see what else runs per frame, then measure it.").split(separator: " ").map(String.init)

    mutating func type(_ bytes: Data) {
        for byte in bytes {
            switch byte {
            case 0x7F, 0x08: if !typed.isEmpty { typed.removeLast() }
            case 0x0D, 0x0A: typed = ""
            case 0x20...0x7E: typed.append(Character(UnicodeScalar(byte)))
            default: break
            }
        }
    }

    /// The screen was replayed from a reset (a resize): nothing of the last render is left to erase.
    mutating func forgetDrawn() {
        drawn = 0
        parkedAbove = 0
    }

    /// One streaming tick: a word or two more of the reply; every 1.5 s the paragraph is done.
    mutating func advance() {
        tick += 1
        let word = Self.words[tick % Self.words.count]
        if reply.isEmpty || (reply.last?.count ?? 0) + word.count + 1 > 46 {
            reply.append(word)
        } else {
            reply[reply.count - 1] += " " + word
        }
    }

    /// The bytes of one render: the erase of the last one, a finished paragraph when due, the live area.
    mutating func redraw(rows: Int) -> String {
        // Back to the end of the last render, then erase it row by row upward.
        var out = parkedAbove > 0 ? "\u{1B}[\(parkedAbove)B\r" : ""
        for row in 0..<drawn {
            out += "\u{1B}[2K" + (row < drawn - 1 ? "\u{1B}[1A" : "")
        }
        if drawn > 0 { out += "\u{1B}[G" }
        if tick > 0, tick % 45 == 0, !reply.isEmpty {
            paragraph += 1
            out += "\u{1B}[1m\u{25CF}\u{1B}[22m " + reply.joined(separator: "\r\n  ").replacingOccurrences(of: "`", with: "") + "\r\n\r\n"
            reply.removeAll()
        }
        let spinner = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"][tick % 6]
        var lines = ["\u{1B}[38;5;174m\(spinner) Thinking\u{2026}\u{1B}[39m \u{1B}[2m(\(tick / 30)s \u{00B7} \u{2191} \(tick * 13) tokens \u{00B7} esc to interrupt)\u{1B}[22m", ""]
        let replyRows = max(1, rows - 7)
        for (index, line) in reply.suffix(replyRows).enumerated() {
            let styled = line.replacingOccurrences(of: "**", with: "")
                .split(separator: "`", omittingEmptySubsequences: false).enumerated()
                .map { $0.offset % 2 == 1 ? "\u{1B}[38;5;153m\($0.element)\u{1B}[39m" : String($0.element) }.joined()
            lines.append((index == 0 ? "\u{1B}[1m\u{25CF}\u{1B}[22m " : "  ") + styled)
        }
        let box = 46
        let shown = String(typed.suffix(box - 4))
        lines += ["", "\u{1B}[2m\u{256D}" + String(repeating: "\u{2500}", count: box) + "\u{256E}\u{1B}[22m",
                  "\u{1B}[2m\u{2502}\u{1B}[22m > " + shown + String(repeating: " ", count: box - 3 - shown.count) + "\u{1B}[2m\u{2502}\u{1B}[22m",
                  "\u{1B}[2m\u{2570}" + String(repeating: "\u{2500}", count: box) + "\u{256F}\u{1B}[22m",
                  "  \u{1B}[2m? for shortcuts\u{1B}[22m"]
        out += lines.joined(separator: "\r\n") + "\r\n"
        drawn = lines.count + 1
        // The cursor goes to the end of the typed text in the box: 3 rows up (the hint row, the
        // box's bottom edge, and the row after the last newline), after "│ > " and the text.
        parkedAbove = 3
        out += "\u{1B}[3A\u{1B}[\(5 + shown.count)G"
        return out
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
    private var pushed = 0
    private var received = 0
    private var receiveCalls = 0

    init(id: UInt32) { self.id = id }

    /// Lines the fake daemon pushed, lines the app read, reads asked for, and the backlog.
    func counts() -> [String: Int] {
        lock.withLock { ["pushed": pushed, "received": received, "receiveCalls": receiveCalls, "backlog": queue.count - head] }
    }

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
            pushed += lines.count
            guard let waiter, head < queue.count else { return nil }
            self.waiter = nil
            let next = queue[head]
            head += 1
            received += 1
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
                receiveCalls += 1
                if head < queue.count {
                    let next = queue[head]
                    head += 1
                    received += 1
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
