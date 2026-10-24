import CmuxMobileModel
import CmuxMobileTerminal
import Foundation

/// What one attach-stream event line means for the terminal, in order.
enum DaemonTerminalInbound: Sendable, Equatable {
    /// Bytes for the mirror.
    case output(Data)
    /// The program entered or left the alternate screen (after the bytes that switched).
    case alternateScreen(Bool)
    /// The Mac terminal's rows (`vt-state`, `resized`).
    case rows(Int)
    /// The Mac terminal's columns (`vt-state`, `resized`), before its rows.
    case columns(Int)
    /// The authoritative mirror changed size: reset the local mirror before the
    /// replay. `alternate` is the alternate screen state the replay ends in, so
    /// a TUI that stays on screen across a resize is never reported as leaving
    /// and re-entering it (that off/on flicker resized the PTY back and forth,
    /// design/terminal R2-1).
    case resetMirror(alternate: Bool)
    /// The daemon ended the surface.
    case detached(reason: String?)
    /// A `resized` at the grid the mirror already holds: kept, not replayed.
    case sameGridResize(columns: Int, rows: Int)
    /// The terminal's shared size state changed (`size-state`, shared-sizing-v1).
    case sizeState(TerminalSizeState, selfParticipant: String?)
}

/// Decodes attach-stream event lines (JSON, base64) and follows the alternate
/// screen. Pure, so it runs off the main thread: a flood of `output` lines
/// costs the main thread nothing until the screen takes the bytes.
struct DaemonTerminalEventParser: Sendable {
    let surface: Int
    private var detector = AlternateScreenDetector()
    /// The Mac's grid this mirror holds (from `vt-state` and `resized`).
    private var grid: (columns: Int, rows: Int)?

    init(surface: Int) { self.surface = surface }

    mutating func parse(_ line: Data) -> [DaemonTerminalInbound] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return [] }
        if let id = object["surface"] as? Int, id != surface { return [] }
        var out: [DaemonTerminalInbound] = []
        switch event {
        case "vt-state":
            if let cols = object["cols"] as? Int, cols > 0 { out.append(.columns(cols)) }
            if let rows = object["rows"] as? Int, rows > 0 { out.append(.rows(rows)) }
            noteGrid(object)
            // The attach's replay rebuilds the whole screen: its final
            // alternate screen state goes first, then its bytes, like a
            // `resized` replay. A reattach to a TUI that is still running
            // then never leaves TUI mode (termfix-r13 D2: the page flipped to
            // the empty primary screen, blank ~170 ms, then half drawn), and
            // a replay back on the primary screen leaves it before its rows.
            detector = AlternateScreenDetector()
            let chunks = [object["data"] as? String, object["pending"] as? String]
                .compactMap { $0.flatMap { Data(base64Encoded: $0) } }.filter { !$0.isEmpty }
            for chunk in chunks { _ = detector.scan(chunk) }
            out.append(.alternateScreen(detector.isActive))
            out.append(contentsOf: chunks.map { .output($0) })
        case "output":
            emit(object["data"] as? String, into: &out)
        case "resized":
            if let cols = object["cols"] as? Int, cols > 0 { out.append(.columns(cols)) }
            if let rows = object["rows"] as? Int, rows > 0 { out.append(.rows(rows)) }
            // termqa V5-4: the Mac sends `resized` with a replay for a change
            // of its cell pixels alone (`commit_geometry_for_runtime` in
            // cmux-tui-core's pty_surface.rs), e.g. when a new tab's view
            // appears. The grid is the one this mirror holds, and the ordered
            // stream already brought it to the replay's state (an incomplete
            // sequence included), so the screen is kept: no reset, no replay.
            if let cols = object["cols"] as? Int, let rows = object["rows"] as? Int,
               let grid, grid.columns == cols, grid.rows == rows {
                out.append(.sameGridResize(columns: cols, rows: rows))
                break
            }
            noteGrid(object)
            // The authoritative mirror changed size: start over from the replay,
            // whose final alternate screen state goes with the reset.
            detector = AlternateScreenDetector()
            let chunks = [(object["replay"] as? String) ?? (object["data"] as? String), object["pending"] as? String]
                .compactMap { $0.flatMap { Data(base64Encoded: $0) } }.filter { !$0.isEmpty }
            for chunk in chunks { _ = detector.scan(chunk) }
            out.append(.resetMirror(alternate: detector.isActive))
            out.append(contentsOf: chunks.map { .output($0) })
        case "detached":
            out.append(.detached(reason: object["reason"] as? String))
        case "size-state":
            if let state = TerminalSizeState.decode(object["state"]) {
                out.append(.sizeState(state, selfParticipant: object["self_participant"] as? String))
            }
        default:
            break
        }
        return out
    }

    private mutating func noteGrid(_ object: [String: Any]) {
        if let cols = object["cols"] as? Int, let rows = object["rows"] as? Int, cols > 0, rows > 0 {
            grid = (cols, rows)
        }
    }

    private mutating func emit(_ base64: String?, into out: inout [DaemonTerminalInbound]) {
        guard let base64, let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        out.append(.output(data))
        if let alternate = detector.scan(data) { out.append(.alternateScreen(alternate)) }
    }
}

/// Hands parsed events from the reader to the main actor: one main-queue hop
/// per batch, however many lines arrived since the last one. The reader waits
/// (and stops reading the channel) while more than `highWater` bytes are
/// waiting for the main actor, or while the screen asked for a pause
/// (``DaemonTerminalSession/setOutputPaused(_:)``).
final class DaemonTerminalInbox: @unchecked Sendable {
    static let highWater = 4 << 20

    private let lock = NSLock()
    private var items: [DaemonTerminalInbound] = []
    private var bytes = 0
    private var scheduled = false
    private var paused = false
    private var closed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let deliver: @Sendable ([DaemonTerminalInbound]) -> Void
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// `deliver` runs on the main actor with every event queued since the last call.
    init(
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) },
        deliver: @escaping @Sendable ([DaemonTerminalInbound]) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// Queues events; waits first while the screen is behind.
    func push(_ events: [DaemonTerminalInbound]) async {
        guard !events.isEmpty else { return }
        await waitForRoom()
        let size = events.reduce(0) { if case .output(let data) = $1 { $0 + data.count } else { $0 } }
        let needsSchedule: Bool = lock.withLock {
            guard !closed else { return false }
            items += events
            bytes += size
            defer { scheduled = true }
            return !scheduled
        }
        if needsSchedule { schedule { [self] in drain() } }
    }

    private func waitForRoom() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if closed || (!paused && bytes < Self.highWater) { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Main queue: delivers everything queued.
    private func drain() {
        let (batch, resume): ([DaemonTerminalInbound], CheckedContinuation<Void, Never>?) = lock.withLock {
            let batch = items
            items.removeAll(keepingCapacity: true)
            bytes = 0
            scheduled = false
            return (batch, takeWaiterIfReady())
        }
        resume?.resume()
        deliver(batch)
    }

    func setPaused(_ paused: Bool) {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            self.paused = paused
            return takeWaiterIfReady()
        }
        resume?.resume()
    }

    /// The channel ended: nothing more is delivered and the reader never waits.
    func close() {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            closed = true
            items.removeAll()
            bytes = 0
            return takeWaiterIfReady()
        }
        resume?.resume()
    }

    private func takeWaiterIfReady() -> CheckedContinuation<Void, Never>? {
        guard let waiter, closed || (!paused && bytes < Self.highWater) else { return nil }
        self.waiter = nil
        return waiter
    }

    var pendingBytes: Int { lock.withLock { bytes } }
}
