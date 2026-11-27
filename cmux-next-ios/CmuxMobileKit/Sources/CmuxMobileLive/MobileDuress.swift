// DEBUG and Demo builds only: the offline duress player is never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileAgentChat
import CmuxMobileTerminal
import Darwin
import Foundation
import os
import UIKit

/// Leo, 2026-11-22: "we should almost always be doing this. always. testing under duress. you should
/// also be able to simulate duress "offline" aka without a true agent thing, just like how i
/// introduced that stuff in the gui."
///
/// DEBUG only. The iPhone's offline duress simulator, the reader half (cmux-next-ios/design/duress-sim.md).
/// `cmux-duress gen` (cmux-tui/crates/cmux-duress) writes a folder; its path in the `CmuxMobileDuress`
/// default (the fleet writes the simulator's global domain: `defaults write -g CmuxMobileDuress DIR`)
/// or in `CMUX_MOBILE_DURESS` turns this on. Unset, nothing here runs.
///
/// It is a player: every knob is already resolved in `duress.json` and every delivery time is in the
/// files; nothing here shapes or times anything of its own. While any UI bench drives the app it
/// - spins `cpu_threads` utility threads, each busy `cpu_duty` of every 10 ms;
/// - feeds `pty-history.bin` to every terminal page as it attaches (before the session's own
///   output), then plays `pty-stream.jsonl` on its schedule, looped, through the page's own output
///   path (``TerminalDuress``), and the same into `panes - 1` hidden Ghostty surfaces;
/// - plays `chat.ndjson`'s acpmux records into every chat (``AgentChatDuress``) through the live
///   source's decoder (``AcpmuxRecords``);
/// - seeds the list rig with `workspaces` rows when it runs the workspaces list without a count;
/// - logs one `[duress]` line a second and keeps the same line on a `debug.duress` probe.
@MainActor
public enum MobileDuress {
    static let log = Logger(subsystem: "dev.cmux.mobile", category: "duress")
    private static var player: DuressPlayer?

    /// The duress folder, or nil (no duress).
    static var folder: String? {
        let path = ProcessInfo.processInfo.environment["CMUX_MOBILE_DURESS"]
            ?? UserDefaults.standard.string(forKey: "CmuxMobileDuress")
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// Call once, first thing at launch: before the list rig reads its settings.
    public static func startIfRequested() {
        guard player == nil, let folder else { return }
        let knobs = DuressKnobs(folder: folder)
        guard let knobs else {
            log.error("[duress] no readable duress.json in \(folder, privacy: .public): off")
            NSLog("[duress] no readable duress.json in %@: off", folder)
            return
        }
        // The list rig reads its environment once (`ListStressSettings.shared`): a workspaces list
        // with no count of its own gets the knob's.
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_MOBILE_LIST_SCREEN"] == "workspaces", environment["CMUX_MOBILE_LIST_COUNT"] == nil,
           let workspaces = knobs.int("workspaces"), workspaces > 0 {
            setenv("CMUX_MOBILE_LIST_COUNT", String(workspaces), 0)
        }
        player = DuressPlayer(folder: folder, knobs: knobs)
    }
}

/// `duress.json`, as written.
struct DuressKnobs: Sendable {
    let values: [String: Double]

    init?(folder: String) {
        guard let data = FileManager.default.contents(atPath: folder + "/duress.json"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Knobs and counts may sit at the top or under `knobs` / `counts`.
        var values: [String: Double] = [:]
        for source in [object, object["knobs"] as? [String: Any] ?? [:], object["counts"] as? [String: Any] ?? [:]] {
            for (key, value) in source { if let number = value as? NSNumber { values[key] = number.doubleValue } }
        }
        self.values = values
    }

    func int(_ key: String) -> Int? { values[key].map { Int($0) } }
    func double(_ key: String) -> Double? { values[key] }
}

/// The replay files, read once off the main thread.
struct DuressTape: Sendable {
    struct Chunk: Sendable { let atMs: Double; let bytes: Data }
    struct Record: Sendable { let atMs: Double; let record: JSONValue }

    let history: Data
    let stream: [Chunk]
    /// One pass of the stream (its loop period): `stream_loop_ms` when the folder says, else the last chunk's time.
    let streamLoopMs: Double
    let chat: [Record]

    init(folder: String, knobs: DuressKnobs) {
        history = FileManager.default.contents(atPath: folder + "/pty-history.bin") ?? Data()
        func lines(_ name: String) -> [Data] {
            guard let data = FileManager.default.contents(atPath: folder + "/" + name) else { return [] }
            return data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        }
        stream = lines("pty-stream.jsonl").compactMap { line in
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let at = (object["t_ms"] as? NSNumber)?.doubleValue,
                  let b64 = object["b64"] as? String, let bytes = Data(base64Encoded: b64) else { return nil }
            return Chunk(atMs: at, bytes: bytes)
        }
        streamLoopMs = knobs.double("stream_loop_ms") ?? stream.last?.atMs ?? 0
        let decoder = JSONDecoder()
        chat = lines("chat.ndjson").compactMap { line in
            guard let record = try? decoder.decode(JSONValue.self, from: line) else { return nil }
            return Record(atMs: record["at"]?.numberValue ?? 0, record: record)
        }
    }
}

/// What was delivered, for the readout.
@MainActor
final class DuressCounters {
    var bytesFed = 0
    var recordsDelivered = 0
    var terminals = 0
    var chats = 0
    var hidden = 0
}

@MainActor
final class DuressPlayer {
    private let folder: String
    private let knobs: DuressKnobs
    private let counters = DuressCounters()
    private var tape: DuressTape?
    private var tapeWaiters: [CheckedContinuation<DuressTape, Never>] = []
    private let burner: DuressCPUBurner
    private var hiddenSurfaces: [(TerminalHiddenSurface, TerminalPlayback)] = []
    private let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var readout: Task<Void, Never>?

    init(folder: String, knobs: DuressKnobs) {
        self.folder = folder
        self.knobs = knobs
        burner = DuressCPUBurner(threads: knobs.int("cpu_threads") ?? 0, duty: knobs.double("cpu_duty") ?? 0)
        probe.isUserInteractionEnabled = false
        probe.alpha = 0.02
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "debug.duress"
        probe.accessibilityLabel = "duress loading \(folder)"
        let counters = counters
        TerminalDuress.attach = { [weak self] feed in
            counters.terminals += 1
            return TerminalPlayback(tape: { await self?.loadedTape() }, counters: counters, feed: feed)
        }
        AgentChatDuress.attach = { [weak self] deliver in
            counters.chats += 1
            return ChatPlayback(tape: { await self?.loadedTape() }, counters: counters, deliver: deliver)
        }
        Task.detached(priority: .userInitiated) { [folder, knobs] in
            let tape = DuressTape(folder: folder, knobs: knobs)
            await MainActor.run { self.loaded(tape) }
        }
        burner.start()
        readout = Task { [weak self] in await self?.runReadout() }
    }

    private func loaded(_ tape: DuressTape) {
        self.tape = tape
        for waiter in tapeWaiters { waiter.resume(returning: tape) }
        tapeWaiters.removeAll()
        let line = "loaded \(folder): history=\(tape.history.count)B stream=\(tape.stream.count) chunks loop=\(Int(tape.streamLoopMs))ms chat=\(tape.chat.count) records knobs=\(knobs.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        MobileDuress.log.notice("[duress] \(line, privacy: .public)")
        NSLog("[duress] %@", line)
    }

    /// The tape, once read (a page that attaches before the read is done waits for it).
    func loadedTape() async -> DuressTape {
        if let tape { return tape }
        return await withCheckedContinuation { tapeWaiters.append($0) }
    }

    /// `panes - 1` hidden surfaces, once a window scene exists.
    private func makeHiddenPanesIfDue() {
        let extra = max(0, (knobs.int("panes") ?? 1) - 1)
        guard hiddenSurfaces.count < extra,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // The size of a page of this scene: a hidden pane lays out as a visible one.
        let size = scene.windows.first?.bounds.size ?? scene.coordinateSpace.bounds.size
        while hiddenSurfaces.count < extra {
            let surface = TerminalHiddenSurface(scene: scene, size: size)
            let playback = TerminalPlayback(tape: { [weak self] in await self?.loadedTape() }, counters: counters) { [weak surface] data in
                surface?.feed(data)
            }
            hiddenSurfaces.append((surface, playback))
            counters.hidden += 1
        }
    }

    private func runReadout() async {
        let clock = ContinuousClock()
        let start = clock.now
        var lastBytes = 0
        var lastRecords = 0
        var lastBurn = burner.cpuSeconds()
        var lastProcess = Self.processCPUSeconds()
        var lastTick = clock.now
        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(1))
            makeHiddenPanesIfDue()
            let now = clock.now
            let wall = max(0.001, Double((now - lastTick).components.attoseconds) / 1e18 + Double((now - lastTick).components.seconds))
            lastTick = now
            let burn = burner.cpuSeconds()
            let process = Self.processCPUSeconds()
            let target = Double(knobs.int("cpu_threads") ?? 0) * (knobs.double("cpu_duty") ?? 0) * 100
            let line = String(
                format: "t=%lds fed=%ldKB (+%ldKB/s) records=%ld (+%ld/s) terminals=%ld hidden=%ld chats=%ld cpu burn=%.0f%% target=%.0f%% process=%.0f%%",
                Int((now - start).components.seconds), counters.bytesFed / 1024, (counters.bytesFed - lastBytes) / 1024,
                counters.recordsDelivered, counters.recordsDelivered - lastRecords,
                counters.terminals, counters.hidden, counters.chats,
                (burn - lastBurn) / wall * 100, target, (process - lastProcess) / wall * 100
            )
            lastBytes = counters.bytesFed
            lastRecords = counters.recordsDelivered
            lastBurn = burn
            lastProcess = process
            MobileDuress.log.notice("[duress] \(line, privacy: .public)")
            NSLog("[duress] %@", line)
            probe.accessibilityLabel = "duress " + line
            if let window = Self.keyWindow, probe.window !== window { window.addSubview(probe) }
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    /// CPU time of every thread of the app (getrusage).
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// Plays the tape into one terminal: the history at once, then the stream on its times, looped.
@MainActor
final class TerminalPlayback {
    private var task: Task<Void, Never>?

    init(tape: @escaping @MainActor () async -> DuressTape?, counters: DuressCounters, feed: @escaping @MainActor (Data) -> Void) {
        task = Task {
            guard let tape = await tape() else { return }
            if !tape.history.isEmpty {
                feed(tape.history)
                counters.bytesFed += tape.history.count
            }
            guard !tape.stream.isEmpty else { return }
            let clock = ContinuousClock()
            let start = clock.now
            var pass = 0.0
            while !Task.isCancelled {
                for chunk in tape.stream {
                    let due = start + .milliseconds(Int64(pass * tape.streamLoopMs + chunk.atMs))
                    if due > clock.now { try? await clock.sleep(until: due) }
                    guard !Task.isCancelled else { return }
                    feed(chunk.bytes)
                    counters.bytesFed += chunk.bytes.count
                }
                // A stream with no length plays once.
                guard tape.streamLoopMs > 0 else { return }
                pass += 1
            }
        }
    }

    isolated deinit { task?.cancel() }
}

/// Plays the tape's acpmux records into one chat on their times, through the live source's decoder.
@MainActor
final class ChatPlayback {
    private var task: Task<Void, Never>?

    init(tape: @escaping @MainActor () async -> DuressTape?, counters: DuressCounters,
         deliver: @escaping @MainActor (AgentSessionEvent) -> Void) {
        task = Task {
            guard let tape = await tape(), !tape.chat.isEmpty else { return }
            let clock = ContinuousClock()
            let start = clock.now
            let wallStart = Date().timeIntervalSince1970 * 1000
            var index = 0
            while index < tape.chat.count, !Task.isCancelled {
                let due = start + .milliseconds(Int64(tape.chat[index].atMs))
                if due > clock.now { try? await clock.sleep(until: due) }
                guard !Task.isCancelled else { return }
                // Every record due by now goes in as one change.
                var events: [AgentSessionEvent] = []
                let now = clock.now
                while index < tape.chat.count, start + .milliseconds(Int64(tape.chat[index].atMs)) <= now {
                    let item = tape.chat[index]
                    // `at` is the relative delivery time: the chat shows it as the wall time it plays at.
                    var record = item.record
                    if case .object(var fields) = record {
                        fields["at"] = .number(wallStart + item.atMs)
                        record = .object(fields)
                    }
                    events += AcpmuxRecords(sessionID: record["sessionId"]?.stringValue ?? "duress").map(record)
                    index += 1
                    counters.recordsDelivered += 1
                }
                if events.count == 1 { deliver(events[0]) } else if !events.isEmpty { deliver(.batch(events)) }
            }
        }
    }

    isolated deinit { task?.cancel() }
}

/// `cpu_threads` utility threads, each busy `cpu_duty` of every 10 ms. It reports the CPU time they took.
final class DuressCPUBurner: @unchecked Sendable {
    private let threads: Int
    private let duty: Double
    private let lock = NSLock()
    private var spent: [Double]

    init(threads: Int, duty: Double) {
        self.threads = max(0, threads)
        self.duty = min(1, max(0, duty))
        spent = Array(repeating: 0, count: max(0, threads))
    }

    func start() {
        guard threads > 0, duty > 0 else { return }
        for index in 0..<threads {
            let thread = Thread { [self] in run(index) }
            thread.name = "duress-cpu-\(index)"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// CPU seconds the threads have taken so far.
    func cpuSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return spent.reduce(0, +)
    }

    private func run(_ index: Int) {
        let periodNs: UInt64 = 10_000_000
        let busyNs = UInt64(Double(periodNs) * duty)
        while true {
            let begin = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds - begin < busyNs {}
            let rest = periodNs - min(periodNs, DispatchTime.now().uptimeNanoseconds - begin)
            if rest > 0 { usleep(UInt32(rest / 1000)) }
            var cpu = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu)
            lock.lock()
            spent[index] = Double(cpu.tv_sec) + Double(cpu.tv_nsec) / 1e9
            lock.unlock()
        }
    }
}
#endif
