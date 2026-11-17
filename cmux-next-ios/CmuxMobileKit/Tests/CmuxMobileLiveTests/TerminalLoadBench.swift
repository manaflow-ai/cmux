// The phone's Ghostty surface and the projection are iOS only: the bench runs
// on the kit job's iOS simulator leg.
#if os(iOS)
import CmuxMobileTransport
import Darwin
import Foundation
import Testing
import UIKit
@testable import CmuxMobileLive
@testable import CmuxMobileTerminal

/// Leo, 2026-11-17: "Plus the gosh darn loading of everything needs to be
/// FASTER" and "How did you guys bench anything if nothing got built".
///
/// The terminal load bench: one harness, the same file on every ref it
/// compares. A Mac pane of 120x40 with a shell's history (small: 100 rows; god:
/// 100,000 rows) behind a daemon that answers as cmux-tui does (`vt-state`
/// replays of the screen and the history rows asked for, history windows,
/// `resized` replays, `resolve-terminal`), over a link with a fixed round trip.
/// The session is the one the app builds for a tab
/// (`TerminalSessionChoice.session(live:)`: on a ref with the phone's
/// projection that is the projecting session), and its output goes to a real
/// Ghostty surface, as the page's does. Per case it reports:
///
/// - open: `start` to the first correct frame (the attach's replay parsed by
///   the surface, the grid the phone's);
/// - reattach: a dropped link (background, then foreground) and `reconnect`
///   to the replay parsed again;
/// - scrollback: `loadOlderHistory` until the mirror holds line 1 of the
///   history (`historyRowsOmitted == 0`), each step parsed before the next;
/// - cached frame: a phone-size JPEG of the page read and decoded (what a
///   cooled tab or a cold launch draws before any network);
///
/// and for each: wall ms, bytes received on the link, main-thread CPU ms, and
/// "wide frames" (grids the page was told whose columns are not the phone's:
/// the Mac's 120 columns drawn on a phone, the "uncompact then squish").
///
/// Opt-in (it allocates and runs for a minute or more): CMUX_TERMINAL_LOAD_BENCH=1,
/// or the CMUX_TICK_HARNESS=1 the fleet step sets for an only= naming
/// `*/TickHarnessCellsTests*`:
/// `cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg test
///   --arg only=CmuxMobileLiveTests/TerminalLoadBench,CmuxMobileLiveTests/TickHarnessCellsTests/none`.
/// Prints TERMINAL-LOAD-SIM lines (also recorded as issues: the fleet step
/// shows failure messages, so the bench reads as failed; its lines are the result).
@MainActor
@Suite(.serialized, .enabled(if: ["CMUX_TERMINAL_LOAD_BENCH", "CMUX_TICK_HARNESS"].contains { ProcessInfo.processInfo.environment[$0] == "1" },
                             "opt-in bench: CMUX_TERMINAL_LOAD_BENCH=1"))
struct TerminalLoadBench {
    nonisolated static let macColumns = 120
    nonisolated static let macRows = 40
    nonisolated static let phoneColumns = 54
    nonisolated static let phoneRows = 38

    // MARK: The Mac

    /// The Mac terminal: `history` rows above a 40-row screen, as cmux-tui
    /// replays them (SGR-colored build-log lines, CRLF).
    final class Mac: @unchecked Sendable {
        let history: Int
        private let lines: [Data]
        private let lock = NSLock()
        private var cache: [String: String] = [:]
        private var _vtStates = 0
        private var _bytes = 0
        private var _attaches = 0

        init(history: Int) {
            self.history = history
            lines = (0..<(history + TerminalLoadBench.macRows)).map { row in
                Data(String(format: "\u{1B}[32m%06ld\u{1B}[0m compiling crate-%ld v0.%ld.%ld (/home/dev/src/project/crates/c%ld) in %ldms",
                            row, row % 977, row % 13, row % 101, row % 31, row % 4099).utf8)
            }
        }

        var vtStates: Int { lock.withLock { _vtStates } }
        var bytes: Int { lock.withLock { _bytes } }
        var attaches: Int { lock.withLock { _attaches } }
        func delivered(_ data: Data, replay: Bool) {
            lock.withLock {
                _bytes += data.count
                if replay { _vtStates += 1 }
            }
        }
        func noteAttach() { lock.withLock { _attaches += 1 } }

        /// The base64 replay of history rows `rows` and the screen.
        func replay(_ rows: Range<Int>) -> String {
            let key = "\(rows.lowerBound)-\(rows.upperBound)"
            if let hit = lock.withLock({ cache[key] }) { return hit }
            var data = Data()
            data.reserveCapacity((rows.count + TerminalLoadBench.macRows) * 96)
            for row in rows { data.append(lines[row]); data.append(contentsOf: [0x0D, 0x0A]) }
            for row in history..<(history + TerminalLoadBench.macRows) {
                data.append(lines[row])
                data.append(contentsOf: row == history + TerminalLoadBench.macRows - 1 ? Array("\r\n$ ".utf8) : [0x0D, 0x0A])
            }
            let encoded = data.base64EncodedString()
            lock.withLock { cache[key] = encoded }
            return encoded
        }
    }

    /// One `daemon` channel to the Mac: cmux-tui's answers, delivered one
    /// round trip after each write, in order.
    final class Channel: LinkChannel, @unchecked Sendable {
        let id: UInt32
        private let mac: Mac
        private let rtt: Double
        private let queue = DispatchQueue(label: "terminal-load-bench.channel")
        private let lock = NSLock()
        private var declaredWindow = false
        private var allowance: Int?
        private var grid = (columns: TerminalLoadBench.macColumns, rows: TerminalLoadBench.macRows)
        private let inbox: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        private var iterator: AsyncStream<Data>.AsyncIterator

        init(id: UInt32, mac: Mac, rtt: Double) {
            self.id = id
            self.mac = mac
            self.rtt = rtt
            (inbox, continuation) = AsyncStream.makeStream()
            iterator = inbox.makeAsyncIterator()
        }

        func send(_ data: Data) async throws {
            let replies = data.split(separator: 0x0A).flatMap { respond(Data($0)) }
            let continuation = continuation
            let mac = mac
            queue.asyncAfter(deadline: .now() + rtt) {
                for (line, replay) in replies {
                    mac.delivered(line, replay: replay)
                    continuation.yield(line)
                }
            }
        }

        func receive() async throws -> Data? { await iterator.next() }

        func close(code: String, reason: String) async { continuation.finish() }

        static func line(_ object: [String: Any]) -> Data {
            var data = try! JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            return data
        }

        /// The replay of `allowance` rows (nil: all) from `start` (nil: the newest).
        private func replayEvent(_ name: String, rows: Int?, start: Int?) -> [String: Any] {
            let history = mac.history
            var event: [String: Any] = ["event": name, "surface": 7, "cols": grid.columns, "rows": grid.rows]
            let range: Range<Int>
            if let rows, let start {
                let from = min(start, history)
                range = from..<min(history, from + rows)
                event["history_rows_omitted"] = from
                event["history_rows_skipped"] = history - range.upperBound
            } else if let rows {
                range = max(0, history - rows)..<history
                event["history_rows_omitted"] = range.lowerBound
            } else {
                range = 0..<history
                if name == "vt-state" { event["history_rows_omitted"] = 0 }
            }
            event[name == "resized" ? "replay" : "data"] = mac.replay(range)
            return event
        }

        private func respond(_ line: Data) -> [(Data, Bool)] {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return [] }
            func reply(_ data: [String: Any] = [:]) -> (Data, Bool) { (Self.line(["id": id, "ok": true, "data": data]), false) }
            return lock.withLock { () -> [(Data, Bool)] in
                switch cmd {
                case "set-client-info":
                    declaredWindow = (object["capabilities"] as? [String] ?? []).contains("attach-replay-history-window-v1")
                    return [reply()]
                case "identify":
                    // As cmux-tui's identify: its attach capabilities and the boot's generation.
                    return [reply(["capabilities": ["attach-initial-size", "size-lease-v1", "attach-replay-history-rows-v1",
                                                    "attach-replay-history-window-v1", "attach-identity-v1"],
                                   "generation": "gen-1"])]
                case "resolve-terminal":
                    return [reply(["surface": 7, "terminal_id": object["terminal_id"] ?? ""])]
                case "attach-surface":
                    // `attach-identity-v1`: the boot and the terminal, before any stream.
                    if let generation = object["expected_generation"] as? String, generation != "gen-1" {
                        return [(Self.line(["id": id, "ok": false, "error": "attachment_generation_mismatch"]), false)]
                    }
                    if let terminal = object["expected_terminal_id"] as? String, terminal != "term_load_bench" {
                        return [(Self.line(["id": id, "ok": false, "error": "attachment_terminal_mismatch"]), false)]
                    }
                    mac.noteAttach()
                    if let columns = object["cols"] as? Int, let rows = object["rows"] as? Int { grid = (columns, rows) }
                    allowance = object["replay_history_rows"] as? Int
                    let event = replayEvent("vt-state", rows: allowance, start: object["replay_history_start"] as? Int)
                    return [(Self.line(event), true), reply(["lease": "l1"])]
                case "resize-surface":
                    guard let columns = object["cols"] as? Int, let rows = object["rows"] as? Int,
                          columns != grid.columns || rows != grid.rows else { return [reply()] }
                    grid = (columns, rows)
                    // cmux-tui: a viewer that declared the window gets the newest
                    // rows it asked for; an older one the whole history.
                    let event = replayEvent("resized", rows: declaredWindow ? allowance : nil, start: nil)
                    return [reply(), (Self.line(event), true)]
                default:
                    return [reply()]
                }
            }
        }
    }

    // MARK: The page

    /// What the page does with the session's events: output to a Ghostty
    /// surface (parsed off the main thread, as the page's output pump does).
    @MainActor final class Page {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 760))
        var pending = 0
        var lastActivity = CFAbsoluteTimeGetCurrent()
        var lastParsed = CFAbsoluteTimeGetCurrent()
        var attached = false
        var alternate = false
        var wideFrames = 0

        init() {
            window.isHidden = false
            window.addSubview(surface)
        }

        func take(_ event: TerminalSessionEvent) {
            lastActivity = CFAbsoluteTimeGetCurrent()
            switch event {
            case .output(let data):
                pending += 1
                surface.feed(data, completion: { [weak self] in
                    guard let self else { return }
                    self.pending -= 1
                    self.lastParsed = CFAbsoluteTimeGetCurrent()
                    self.lastActivity = self.lastParsed
                })
            case .connection(let state):
                attached = state.isAttached
            case .alternateScreen(let on):
                alternate = on
            case .hostGrid(let columns, _):
                if !alternate, columns != TerminalLoadBench.phoneColumns { wideFrames += 1 }
            default:
                break
            }
        }

        func close() {
            surface.removeFromSuperview()
            window.isHidden = true
        }
    }

    // MARK: Measuring

    /// The main thread's Mach port, taken on the main thread when the test starts.
    nonisolated(unsafe) static var mainThreadPort: mach_port_t = 0

    /// The main thread's CPU time so far (user + system), in ms.
    nonisolated static func mainThreadCPU() -> Double {
        let port = mainThreadPort
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    struct Sample {
        var ms: Double
        var bytes: Int
        var mainMs: Double
        var wide: Int
        var steps = 1
        var reached = true
    }

    struct Mark {
        let wall = CFAbsoluteTimeGetCurrent()
        let cpu = TerminalLoadBench.mainThreadCPU()
        let bytes: Int
        let wide: Int
        let replays: Int
        let attaches: Int
    }

    static func mark(_ mac: Mac, _ page: Page) -> Mark {
        Mark(bytes: mac.bytes, wide: page.wideFrames, replays: mac.vtStates, attaches: mac.attaches)
    }

    /// Waits for `replays` more replays delivered and the page's surface to
    /// have parsed everything it got, with no event for 60 ms; the time is the
    /// last parse's.
    static func settle(_ mac: Mac, _ page: Page, from mark: Mark, replays: Int = 1, limit: Double = 240,
                       until extra: @MainActor () -> Bool = { true }) async -> Sample {
        let deadline = mark.wall + limit
        while CFAbsoluteTimeGetCurrent() < deadline {
            let now = CFAbsoluteTimeGetCurrent()
            if mac.vtStates >= mark.replays + replays, page.pending == 0, now - page.lastActivity > 0.06, extra() { break }
            try? await Task.sleep(for: .milliseconds(4))
        }
        let reached = CFAbsoluteTimeGetCurrent() < deadline
        // The polling itself is on the main thread: its cost is in mainMs (a few ms).
        return Sample(ms: (page.lastParsed - mark.wall) * 1000, bytes: mac.bytes - mark.bytes,
                      mainMs: mainThreadCPU() - mark.cpu, wide: page.wideFrames - mark.wide, reached: reached)
    }

    struct Rig {
        let mac: Mac
        let page: Page
        let daemon: DaemonTerminalSession
        let session: any TerminalSession
        let channels: Channels
    }

    final class Channels: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [Channel] = []
        private var next: UInt32 = 1
        func make(_ mac: Mac, rtt: Double) -> Channel {
            lock.withLock {
                defer { next += 2 }
                let channel = Channel(id: next, mac: mac, rtt: rtt)
                all.append(channel)
                return channel
            }
        }
        var list: [Channel] { lock.withLock { all } }
    }

    static func rig(_ mac: Mac, rtt: Double) -> Rig {
        let channels = Channels()
        // As `LiveCoordinator.terminalSession` builds a tab's session.
        let daemon = DaemonTerminalSession(
            surface: 7, terminalID: "term_load_bench", programName: "zsh",
            clientInfo: ["name": "load bench", "kind": "ios", "device_kind": "iphone", "device_name": "load bench", "device_id": "bench"],
            open: { DaemonClient(channel: channels.make(mac, rtt: rtt), eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) },
            openInput: { DaemonClient(channel: channels.make(mac, rtt: rtt), eventCapacity: BoundedDaemonEventBuffer.defaultCapacity) })
        daemon.reattachBackoff = []
        daemon.macName = "Bench Mac"
        let session = TerminalSessionChoice.session(live: daemon, mockDataEnabled: false, macName: "Mac", programName: "zsh")
        return Rig(mac: mac, page: Page(), daemon: daemon, session: session, channels: channels)
    }

    /// Open: the page measures its grid, claims it (it is on screen) and starts the session.
    static func open(_ rig: Rig) async -> Sample {
        let mark = mark(rig.mac, rig.page)
        rig.session.setClaimsSize(true)
        rig.session.resize(columns: phoneColumns, rows: phoneRows)
        rig.session.start { [page = rig.page] in page.take($0) }
        return await settle(rig.mac, rig.page, from: mark) { rig.page.attached }
    }

    /// Background and foreground: the link drops, the coordinator reconnects.
    static func reattach(_ rig: Rig) async -> Sample {
        for channel in rig.channels.list { await channel.close(code: "eof", reason: "background") }
        let gone = CFAbsoluteTimeGetCurrent() + 5
        while rig.daemon.isAttached, CFAbsoluteTimeGetCurrent() < gone { try? await Task.sleep(for: .milliseconds(2)) }
        // Let the drop's own events land before the clock starts.
        try? await Task.sleep(for: .milliseconds(100))
        let mark = mark(rig.mac, rig.page)
        rig.daemon.reconnect()
        return await settle(rig.mac, rig.page, from: mark) { rig.daemon.isAttached }
    }

    /// Scrolling back to line 1, as the page asks its session for older rows
    /// (a projecting session re-wraps the rows it holds first, then fetches
    /// the Mac's): each step parsed before the next, until the Mac has no
    /// older row left and the session has nothing more to show.
    static func scrollback(_ rig: Rig, limit: Double) async -> Sample {
        let start = mark(rig.mac, rig.page)
        var steps = 0
        var idleSince: CFAbsoluteTime?
        while CFAbsoluteTimeGetCurrent() - start.wall < limit {
            let step = mark(rig.mac, rig.page)
            let activity = rig.page.lastActivity
            guard rig.session.loadOlderHistory() else {
                // Nothing more (or a fetch waits for the last one's old attach to close).
                if rig.daemon.historyRowsOmitted == 0, CFAbsoluteTimeGetCurrent() - (idleSince ?? step.wall) > 0.6 { break }
                if idleSince == nil { idleSince = step.wall }
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            idleSince = nil
            // Output during the call: the session re-wrapped rows it holds; else a Mac fetch
            // goes out (an attach reaches the daemon), or nothing did (a throttled call).
            let local = rig.page.lastActivity != activity
            if !local {
                let sent = CFAbsoluteTimeGetCurrent() + 0.5
                while rig.mac.attaches == step.attaches, CFAbsoluteTimeGetCurrent() < sent { try? await Task.sleep(for: .milliseconds(2)) }
                if rig.mac.attaches == step.attaches { continue }
            }
            steps += 1
            _ = await settle(rig.mac, rig.page, from: step, replays: local ? 0 : 1, limit: limit)
        }
        var sample = Sample(ms: (rig.page.lastParsed - start.wall) * 1000, bytes: rig.mac.bytes - start.bytes,
                            mainMs: mainThreadCPU() - start.cpu, wide: rig.page.wideFrames - start.wide)
        sample.steps = steps
        sample.reached = rig.daemon.historyRowsOmitted == 0
        return sample
    }

    /// The cached frame: a phone-size JPEG of a terminal page (as
    /// `TerminalFrameStore` keeps it) read from disk and decoded for display.
    static func cachedFrame() throws -> Sample {
        let size = CGSize(width: 1179, height: 2556)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 30, weight: .regular),
                                                             .foregroundColor: UIColor.green]
            for row in 0..<70 {
                NSString(string: String(format: "%06d compiling crate-%d v0.%d.%d in %dms", row, row * 7, row % 13, row % 101, row * 31))
                    .draw(at: CGPoint(x: 8, y: CGFloat(row) * 36), withAttributes: attributes)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-load-bench-frame.jpg")
        let jpeg = try #require(image.jpegData(compressionQuality: 0.7))
        try jpeg.write(to: url)
        let cpu = mainThreadCPU()
        let started = CFAbsoluteTimeGetCurrent()
        let data = try Data(contentsOf: url)
        let decoded = UIImage(data: data)?.preparingForDisplay()
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        #expect(decoded != nil)
        return Sample(ms: ms, bytes: 0, mainMs: mainThreadCPU() - cpu, wide: 0)
    }

    static func median(_ samples: [Sample]) -> Sample {
        samples.sorted { $0.ms < $1.ms }[samples.count / 2]
    }

    static func describe(_ sample: Sample) -> String {
        let reached = sample.reached ? "" : " (NOT reached)"
        return String(format: "%.0f ms, %ld bytes, main %.0f ms, wide frames %ld, steps %ld", sample.ms, sample.bytes, sample.mainMs, sample.wide, sample.steps) + reached
    }

    @Test func loadingATerminalTab() async throws {
        Self.mainThreadPort = mach_thread_self()
        var out: [String] = []
        let projecting = Self.rig(Mac(history: 0), rtt: 0).session is DaemonTerminalSession ? "bytes mirror" : "phone projection"
        out.append("TERMINAL-LOAD-SIM session: \(projecting); Mac pane \(Self.macColumns)x\(Self.macRows), phone \(Self.phoneColumns)x\(Self.phoneRows)")
        out.append("TERMINAL-LOAD-SIM cached frame: \(Self.describe(try Self.cachedFrame()))")
        for rtt in [0.0, 0.04] {
            for (name, history) in [("small", 100), ("god", 100_000)] {
                let mac = Mac(history: history)
                var opens: [Sample] = []
                var reattaches: [Sample] = []
                var last: Rig?
                for _ in 0..<3 {
                    let rig = Self.rig(mac, rtt: rtt)
                    opens.append(await Self.open(rig))
                    reattaches.append(await Self.reattach(rig))
                    if let last { last.session.stop(); last.page.close() }
                    last = rig
                }
                let label = "\(name) rtt=\(Int(rtt * 1000))ms"
                out.append("TERMINAL-LOAD-SIM \(label) open: \(Self.describe(Self.median(opens)))")
                out.append("TERMINAL-LOAD-SIM \(label) reattach: \(Self.describe(Self.median(reattaches)))")
                if let rig = last {
                    let scroll = await Self.scrollback(rig, limit: 180)
                    out.append("TERMINAL-LOAD-SIM \(label) scrollback to line 1: \(Self.describe(scroll))")
                    rig.session.stop()
                    rig.page.close()
                }
                for line in out.suffix(3) { print(line) }
            }
        }
        for line in out { print(line) }
        #expect(out.count > 2)
        for line in out { Issue.record(Comment(rawValue: line)) }
    }
}
#endif
