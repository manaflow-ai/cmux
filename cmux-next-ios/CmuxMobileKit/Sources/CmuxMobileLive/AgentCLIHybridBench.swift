// DEBUG and Demo builds only: the hybrid benchmark is never compiled into Production.
#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import OSLog
import QuartzCore
import SwiftUI

/// DEBUG only. Launch with `-CmuxMobileHybridBench` to replay a recorded agent CLI session
/// (Claude Code, Codex, opencode) into the real terminal screen, the way the Mac's daemon sends
/// it: as PTY bytes (`output` events, today) or as the cells that changed (`agent-cli-frame`,
/// `agent-cli-hybrid-v1`, Settings → Transport → Agent CLI Screen Changes). Only the Mac is
/// faked; `DaemonClient`, `DaemonTerminalSession`, the terminal screen and Ghostty's renderer
/// are the app's own.
///
/// The session file is cmux-tui's `export_sessions_for_the_phone_bench` (cmux-agent-cli-render
/// `tests/parity.rs`): the PTY chunks, the daemon's frames as paced, an attach at the session's
/// `working` moment both ways, and the Mac's real screen text at each moment.
///
/// Options (launch arguments, `-Key value`):
/// - `-CmuxMobileHybridBenchFile /path`: the exported session (required).
/// - `-CmuxMobileHybridBenchMode pty|hybrid|lean`: how the fake Mac sends it (default pty):
///   PTY bytes, `agent-cli-frame` events (v1), or lean `agent-cli-lean` events (v2), which
///   the phone declares too, so a Mac that knows them sends those.
///
/// It attaches at the `working` moment (first frame: from the attach request until the screen
/// shows the Mac's screen of that moment), then streams the rest at the recorded pace. At each
/// later moment it pauses, waits for the screen to settle and compares it cell for cell with the
/// Mac's screen: in pty mode with the real screen at that moment, in hybrid mode with the screen
/// as of the newest frame (and, for the record, with the real one). The summary goes to
/// `Documents/hybrid-bench.json`, the log (`[hybrid-bench]`) and, as one line of JSON, the
/// accessibility label of `hybrid-bench.result` for the UI test to read.
///
/// The energy bench's `typical-hour-*` cases (`scripts/ci/cmux-next-ios-sim.sh energy`) set
/// the same options as environment variables (`CMUX_MOBILE_HYBRID_BENCH_FILE`, `_MODE`) and
/// `CMUX_MOBILE_HYBRID_BENCH_LOOP=1`: after the attach the session's stream plays again and
/// again at its recorded pace, with `FRAMELOG list-stress holding hybrid` once it attached and
/// the received-bytes total each second (`ReceivedByteCount`), while the bench samples the app.
public struct AgentCLIHybridBenchRoot: View {
    @State private var bench = AgentCLIHybridBench()

    public init() {}

    public static var isRequested: Bool {
        CommandLine.arguments.contains("-CmuxMobileHybridBench")
            || ProcessInfo.processInfo.environment["CMUX_MOBILE_HYBRID_BENCH_FILE"] != nil
    }

    public var body: some View {
        NavigationStack {
            TerminalScreen(model: bench.model)
        }
        .overlay(alignment: .top) {
            // Only once the bench is done: the UI test waits for it to exist.
            if !bench.result.isEmpty {
                Text(bench.result)
                    .lineLimit(2)
                    .accessibilityIdentifier("hybrid-bench.result")
                    .accessibilityLabel(bench.result)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
        }
        .task { await bench.run() }
    }
}

@MainActor @Observable
final class AgentCLIHybridBench {
    let model: TerminalModel
    private(set) var result = ""
    private let daemon: HybridBenchDaemon
    private let probe = TerminalBenchProbe()
    private let hybrid: Bool
    private let mode: String
    /// The energy bench's loop (`CMUX_MOBILE_HYBRID_BENCH_LOOP=1`).
    private let loops: Bool

    init() {
        let defaults = UserDefaults.standard
        let environment = ProcessInfo.processInfo.environment
        loops = environment["CMUX_MOBILE_HYBRID_BENCH_LOOP"] == "1"
        let mode = defaults.string(forKey: "CmuxMobileHybridBenchMode")
            ?? environment["CMUX_MOBILE_HYBRID_BENCH_MODE"] ?? "pty"
        self.mode = mode
        hybrid = mode == "hybrid" || mode == "lean"
        // The setting the session reads at attach (off unless this run is hybrid).
        defaults.set(hybrid, forKey: DaemonTerminalSession.agentCLIHybridDefaultsKey)
        let session = (defaults.string(forKey: "CmuxMobileHybridBenchFile") ?? environment["CMUX_MOBILE_HYBRID_BENCH_FILE"])
            .flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { BenchSession($0) }
        daemon = HybridBenchDaemon(session: session, hybrid: hybrid, lean: mode == "lean")
        let daemon = daemon
        let terminal = DaemonTerminalSession(
            surface: 1,
            open: { DaemonClient(channel: daemon.main, eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) },
            openInput: { DaemonClient(channel: daemon.lane, eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) }
        )
        model = TerminalModel(session: terminal, artifactSource: MockArtifactSource(), title: "hybrid bench")
    }

    private func log(_ text: String) { NSLog("[hybrid-bench] %@", text) }

    func run() async {
        TerminalBenchProbe.shared = probe
        let clock = ContinuousClock()
        guard let session = daemon.session else {
            finish(["error": "no session file (-CmuxMobileHybridBenchFile)"])
            return
        }
        // First frame: from the attach request to the first presented frame that shows the
        // Mac's screen of the attach moment.
        let want = hybrid ? session.attachShown : session.attachText
        var firstFrameMs: Double?
        var firstParity = Parity()
        let deadline = clock.now + .seconds(20)
        var seen = 0
        while clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(2))
            guard let attachAt = daemon.attachAt else { continue }
            let presents = probe.take().presents
            guard presents != seen else { continue }
            seen = presents
            guard let rows = probe.readScreen?() else { continue }
            firstParity = Parity(phone: rows, mac: want, columns: session.columns, rows: session.rows)
            if firstParity.isWhole {
                firstFrameMs = ((CACurrentMediaTime() - attachAt) * 10_000).rounded() / 10
                break
            }
        }
        log("\(mode) attach: first frame \(firstFrameMs.map { "\($0) ms" } ?? "never whole") parity \(firstParity.percent)%")
        if loops {
            await loop(session)
            return
        }
        // The rest of the session at its recorded pace, paused at each moment.
        let streamStart = daemon.streamedBytes
        let playStart = CACurrentMediaTime()
        var paused: CFTimeInterval = 0
        var moments: [[String: Any]] = []
        var total = Parity()
        var realTotal = Parity()
        for moment in session.moments where moment.atMs > session.attachMs {
            let (daemon, from, until, attachMs) = (daemon, playStart + paused, moment.atMs, session.attachMs)
            await Task.detached { await daemon.play(until: until, from: from, attachMs: attachMs) }.value
            let pause = CACurrentMediaTime()
            let rows = await settledScreen(clock)
            let parity = Parity(phone: rows, mac: hybrid ? moment.shown : moment.text, columns: session.columns, rows: session.rows)
            let real = Parity(phone: rows, mac: moment.text, columns: session.columns, rows: session.rows)
            total.add(parity)
            realTotal.add(real)
            moments.append(["name": moment.name, "parity": parity.percent, "parityVsRealScreen": real.percent,
                            "differing": parity.differing])
            log("\(mode) \(moment.name): parity \(parity.percent)% (vs the real screen \(real.percent)%)")
            paused += CACurrentMediaTime() - pause
        }
        let streamed = daemon.streamedBytes - streamStart
        let seconds = Double(session.durationMs - session.attachMs) / 1000
        let summary: [String: Any] = [
            "mode": mode,
            "capabilityDeclared": daemon.declaredHybrid,
            "attachBytes": daemon.attachBytes,
            "firstFrameMs": firstFrameMs ?? -1,
            "firstFrameParity": firstParity.percent,
            "streamedBytes": streamed,
            "streamedSeconds": seconds,
            "bytesPerSecond": (Double(streamed) / max(seconds, 0.001)).rounded(),
            "wholeSessionBytesPerSecond": session.wholeSessionRate(mode).rounded(),
            "parity": total.percent,
            "parityVsRealScreen": realTotal.percent,
            "moments": moments,
        ]
        finish(summary)
    }

    /// The energy bench: the stream after the attach moment, again and again at its recorded
    /// pace, until the bench ends the app.
    private func loop(_ session: BenchSession) async {
        ReceivedByteCount.shared.startLogging()
        Logger(subsystem: "dev.cmux.mobile", category: "frames").notice("FRAMELOG list-stress holding hybrid")
        let daemon = daemon
        while !Task.isCancelled {
            daemon.rewind()
            let (from, until, attachMs) = (CACurrentMediaTime(), session.durationMs, session.attachMs)
            await Task.detached { await daemon.play(until: until, from: from, attachMs: attachMs) }.value
            // The session's quiet tail, then the next pass.
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// The screen once nothing changed for 300 ms (at most 5 s).
    private func settledScreen(_ clock: ContinuousClock) async -> [String] {
        let deadline = clock.now + .seconds(5)
        var last = probe.take()
        var stableSince = clock.now
        while clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(25))
            let now = probe.take()
            if now.presents != last.presents || now.processed != last.processed {
                stableSince = clock.now
                last = now
            } else if clock.now - stableSince >= .milliseconds(300) {
                break
            }
        }
        return probe.readScreen?() ?? []
    }

    private func finish(_ summary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) else { return }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("hybrid-bench.json"))
        }
        result = String(decoding: data, as: UTF8.self)
        log("summary \(result)")
    }
}

/// Cells of the phone's screen equal to the Mac's (text only; a no-break space equals a space),
/// over the Mac's grid. The rows are
/// aligned at the bottom: the phone's text rows hold its scrollback above the screen.
struct Parity {
    var same = 0
    var total = 0
    /// The first cells that differ: "row,column phone|mac".
    var differing: [String] = []

    init() {}

    init(phone: [String], mac: String, columns: Int, rows: Int) {
        var macRows = mac.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        macRows = Array(macRows.prefix(rows))
        macRows += Array(repeating: "", count: max(0, rows - macRows.count))
        func trimmed(_ rows: [String]) -> [String] {
            var rows = rows.map { String($0.reversed().drop { $0 == " " }.reversed()) }
            while rows.last?.isEmpty == true { rows.removeLast() }
            return rows
        }
        let macLast = trimmed(macRows).count
        let phoneRows = trimmed(phone)
        for row in 0..<rows {
            // The Mac's last written row lines up with the phone's.
            let index = phoneRows.count - macLast + row
            let phoneRow = index >= 0 && index < phoneRows.count ? Array(phoneRows[index]) : []
            let macRow = Array(macRows[row])
            for column in 0..<columns {
                let a = column < phoneRow.count ? phoneRow[column] : " "
                let b = column < macRow.count ? macRow[column] : " "
                // A no-break space is a blank, as cmux-tui's `Cell::is_blank` counts it: the
                // hybrid stream sends it as one (it looks the same), the PTY as itself.
                if a == b || (a == " " || a == "\u{a0}") && (b == " " || b == "\u{a0}") {
                    same += 1
                } else if differing.count < 6 {
                    differing.append("\(row),\(column) \(a)|\(b)")
                }
                total += 1
            }
        }
    }

    var isWhole: Bool { total > 0 && same == total }
    var percent: Double { total == 0 ? 0 : (Double(same) / Double(total) * 1000).rounded() / 10 }

    mutating func add(_ other: Parity) {
        same += other.same
        total += other.total
    }
}

/// An exported session (`export_sessions_for_the_phone_bench`).
struct BenchSession {
    struct Moment {
        let name: String
        let atMs: Int
        let text: String
        let shown: String
    }

    let columns: Int
    let rows: Int
    let durationMs: Int
    /// PTY chunks: ms from the start, bytes.
    let pty: [(atMs: Int, data: Data)]
    /// The daemon's `agent-cli-frame` events: ms from the start, the event.
    let frames: [(atMs: Int, event: [String: Any])]
    let attachMs: Int
    let attachPTY: Data
    let attachText: String
    let attachFrame: [String: Any]
    /// The same frames as lean `agent-cli-lean` events of an attach at `attachMs`: its first
    /// frame (``attachLean``) and the rest.
    let leanFrames: [(atMs: Int, event: [String: Any])]
    let attachLean: [String: Any]
    let attachShown: String
    let moments: [Moment]

    init?(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = root["cols"] as? Int, let rows = root["rows"] as? Int,
              let duration = root["duration_ms"] as? Int,
              let pty = root["pty"] as? [[Any]], let frames = root["frames"] as? [[Any]],
              let attach = root["attach"] as? [String: Any],
              let attachMs = attach["t_ms"] as? Int,
              let attachPTY = (attach["pty"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let attachFrame = attach["hybrid"] as? [String: Any],
              let moments = root["moments"] as? [[String: Any]] else { return nil }
        self.columns = columns
        self.rows = rows
        durationMs = duration
        self.pty = pty.compactMap { pair in
            guard pair.count == 2, let at = pair[0] as? Int,
                  let bytes = (pair[1] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return (at, bytes)
        }
        self.frames = frames.compactMap { pair in
            guard pair.count == 2, let at = pair[0] as? Int, let event = pair[1] as? [String: Any] else { return nil }
            return (at, event)
        }
        self.attachMs = attachMs
        self.attachPTY = attachPTY
        attachText = attach["text"] as? String ?? ""
        self.attachFrame = attachFrame
        attachLean = attach["lean"] as? [String: Any] ?? [:]
        leanFrames = (root["lean_frames"] as? [[Any]] ?? []).compactMap { pair in
            guard pair.count == 2, let at = pair[0] as? Int, let event = pair[1] as? [String: Any] else { return nil }
            return (at, event)
        }
        attachShown = attach["shown"] as? String ?? ""
        self.moments = moments.compactMap { object in
            guard let name = object["name"] as? String, let at = object["t_ms"] as? Int else { return nil }
            return Moment(name: name, atMs: at, text: object["text"] as? String ?? "", shown: object["shown"] as? String ?? "")
        }
    }

    /// Wire bytes per second of the whole session as event lines (JSON, base64), as the
    /// daemon would send them from the start.
    /// (Lean: from the attach moment, the frames the export has.)
    func wholeSessionRate(_ mode: String) -> Double {
        let bytes = switch mode {
        case "hybrid": frames.reduce(0) { $0 + HybridBenchDaemon.line($1.event).count }
        case "lean": leanFrames.reduce(HybridBenchDaemon.line(attachLean).count) { $0 + HybridBenchDaemon.line($1.event).count }
        default: pty.reduce(0) { $0 + HybridBenchDaemon.outputLine($1.data).count }
        }
        if mode == "lean" {
            return Double(bytes) / max(Double(durationMs - attachMs) / 1000, 0.001)
        }
        return Double(bytes) / max(Double(durationMs) / 1000, 0.001)
    }
}

/// The fake Mac: a cmux-tui daemon for surface 1 that answers the attach with the session's
/// screen at its attach moment, then plays the rest of it as `output` or `agent-cli-frame`
/// events on the attach channel.
final class HybridBenchDaemon: @unchecked Sendable {
    let session: BenchSession?
    let hybrid: Bool
    let lean: Bool
    let main = FloodChannel(id: 1)
    let lane = FloodChannel(id: 2)
    private let lock = NSLock()
    private var _attachAt: CFTimeInterval?
    private var _attachBytes = 0
    private var _streamed = 0
    private var _declaredHybrid = false
    private var nextPTY = 0
    private var nextFrame = 0
    /// Where the stream after the attach starts (``rewind()``).
    private var firstPTY = 0
    private var firstFrame = 0
    private var timer: DispatchSourceTimer?

    var attachAt: CFTimeInterval? { lock.withLock { _attachAt } }
    var attachBytes: Int { lock.withLock { _attachBytes } }
    var streamedBytes: Int { lock.withLock { _streamed } }
    var declaredHybrid: Bool { lock.withLock { _declaredHybrid } }

    init(session: BenchSession?, hybrid: Bool, lean: Bool) {
        self.session = session
        self.hybrid = hybrid
        self.lean = lean
        main.onSend = { [weak self] line in self?.request(line, on: self?.main) }
        lane.onSend = { [weak self] line in self?.request(line, on: self?.lane) }
        if let session {
            let attachFrame = session.attachFrame["frame"] as? Int ?? 0
            nextPTY = session.pty.firstIndex { $0.atMs > session.attachMs } ?? session.pty.count
            nextFrame = lean ? 0 : session.frames.firstIndex { ($0.event["frame"] as? Int ?? 0) > attachFrame } ?? session.frames.count
            (firstPTY, firstFrame) = (nextPTY, nextFrame)
        }
    }

    /// The stream after the attach plays again from its start (the energy bench's loop).
    func rewind() {
        lock.withLock { (nextPTY, nextFrame) = (firstPTY, firstFrame) }
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    static func outputLine(_ bytes: Data) -> Data {
        line(["event": "output", "surface": 1, "data": bytes.base64EncodedString()])
    }

    private func request(_ line: Data, on channel: FloodChannel?) {
        guard let channel, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return }
        let reply = Self.line(["id": id, "ok": true, "data": [String: Any]()])
        switch cmd {
        case "set-client-info":
            let wanted = lean ? DaemonTerminalSession.agentCLIHybridLeanCapability : DaemonTerminalSession.agentCLIHybridCapability
            let declared = (object["capabilities"] as? [String])?.contains(wanted) ?? false
            lock.withLock { _declaredHybrid = declared }
            channel.push([reply])
        case "attach-surface":
            guard let session else { channel.push([reply]); return }
            let first: Data
            if hybrid {
                var event = lean ? session.attachLean : session.attachFrame
                event["surface"] = 1
                first = Self.line(event)
            } else {
                first = Self.line([
                    "event": "vt-state", "surface": 1, "cols": session.columns, "rows": session.rows,
                    "history_rows_omitted": 0, "data": session.attachPTY.base64EncodedString(),
                ])
            }
            lock.withLock {
                _attachAt = CACurrentMediaTime()
                _attachBytes = first.count
            }
            channel.push([first, reply])
        default:
            channel.push([reply])
        }
    }

    /// Sends the events from the attach moment up to `until` (ms from the session's start) at
    /// their recorded pace, the attach moment at `from`; returns when they are all sent.
    func play(until: Int, from: CFTimeInterval, attachMs: Int) async {
        guard let session else { return }
        while true {
            let next: (atMs: Int, line: Data)? = lock.withLock {
                if hybrid {
                    let frames = lean ? session.leanFrames : session.frames
                    guard nextFrame < frames.count, frames[nextFrame].atMs <= until else { return nil }
                    defer { nextFrame += 1 }
                    var event = frames[nextFrame].event
                    event["surface"] = 1
                    return (frames[nextFrame].atMs, Self.line(event))
                }
                guard nextPTY < session.pty.count, session.pty[nextPTY].atMs <= until else { return nil }
                defer { nextPTY += 1 }
                return (session.pty[nextPTY].atMs, Self.outputLine(session.pty[nextPTY].data))
            }
            guard let next else { return }
            let due = from + Double(next.atMs - attachMs) / 1000
            let wait = due - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            lock.withLock { _streamed += next.line.count }
            main.push([next.line])
        }
    }
}
#endif
