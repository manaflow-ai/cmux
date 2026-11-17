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
    /// Rows of the Mac's history older than the mirror's oldest row: the
    /// attach's `vt-state` left them out (`history_rows_omitted`,
    /// `attach-replay-history-rows-v1`); 0 for a whole replay. (A `resized`
    /// replay, always whole, says so with ``resetMirror(alternate:)``.)
    case historyRowsOmitted(Int)
    /// An `agent-cli-frame` (`agent-cli-hybrid-v1`) was drawn: its stream and frame, which a
    /// reattach names to resume from it; `resumed` when it applied on the screen the mirror
    /// already held (a resume after a drop), so the attach keeps that screen.
    case hybridFrame(stream: String, frame: Int, resumed: Bool)
    /// An agent CLI frame could not be drawn as sent: unreadable, outside its grid, a control
    /// character in a cell, or not on the frame the mirror holds (a lost, repeated or
    /// reordered numbered frame). Nothing of it was drawn, and this attach draws no later
    /// frame: the session attaches again for a full resync, or in bytes mode
    /// (``DaemonTerminalSession``), so the phone never shows a wrong screen it cannot see is wrong.
    case hybridFallback(reason: String)
}

/// Decodes attach-stream event lines (JSON, base64) and follows the alternate
/// screen. Pure, so it runs off the main thread: a flood of `output` lines
/// costs the main thread nothing until the screen takes the bytes.
struct DaemonTerminalEventParser: Sendable {
    let surface: Int
    private var detector = AlternateScreenDetector()
    /// The Mac's grid this mirror holds (from `vt-state` and `resized`).
    private var grid: (columns: Int, rows: Int)?
    /// Whether this attach drew an `agent-cli-frame` yet: a later keyframe at another grid starts the mirror over.
    private var drewHybridFrame = false
    /// This attach's lean frames (`agent-cli-lean`): their header and style table.
    private var lean = AgentCLIHybridLeanDecoder()
    /// The stream and frame the mirror shows: the one this attach drew last, or before its
    /// first, the one the attach asked to resume from.
    private var hybridShown: (stream: String, frame: Int)?
    /// A frame failed (``DaemonTerminalInbound/hybridFallback(reason:)``): no later one is drawn.
    private var hybridLost = false
    /// Whether the mirror is on the alternate screen when this attach starts: a resumed agent
    /// CLI stream keeps that screen, and the daemon does not say it again.
    private let resumeAlternate: Bool

    /// `hybridResume`: the stream and frame this attach names to resume from (nil: none);
    /// `alternate`: whether the mirror it resumes on shows the alternate screen.
    init(surface: Int, hybridResume: (stream: String, frame: Int)? = nil, alternate: Bool = false) {
        self.surface = surface
        hybridShown = hybridResume
        resumeAlternate = alternate
    }

    mutating func parse(_ line: Data) -> [DaemonTerminalInbound] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else {
            // A line that is not an event while agent CLI frames come in may have been one.
            return drewHybridFrame ? fallBack("an unreadable line") : []
        }
        if let id = object["surface"] as? Int, id != surface { return [] }
        var out: [DaemonTerminalInbound] = []
        switch event {
        case "vt-state":
            if let cols = object["cols"] as? Int, cols > 0 { out.append(.columns(cols)) }
            if let rows = object["rows"] as? Int, rows > 0 { out.append(.rows(rows)) }
            noteGrid(object)
            // A latest-screen-first replay names the older rows it left out;
            // any other replay holds the whole history.
            out.append(.historyRowsOmitted(max(0, object["history_rows_omitted"] as? Int ?? 0)))
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
        case "agent-cli-frame":
            // An agent CLI's screen as the cells that changed (`agent-cli-hybrid-v1`), drawn
            // into the same mirror as terminal bytes, so it looks as it does from the PTY.
            guard !hybridLost else { break }
            guard let frame = AgentCLIHybridFrame(object) else { return fallBack("an unreadable agent-cli-frame") }
            accept(frame, into: &out)
        case "agent-cli-lean":
            // The same frames, packed (`agent-cli-hybrid-v2`): fewer bytes than the PTY's.
            guard !hybridLost else { break }
            guard let encoded = object["f"] as? String, let bytes = Data(base64Encoded: encoded),
                  let frame = lean.decode(bytes) else { return fallBack("an unreadable agent-cli-lean") }
            accept(frame, into: &out)
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

    /// Stops drawing this attach's agent CLI frames, and says why.
    private mutating func fallBack(_ reason: String) -> [DaemonTerminalInbound] {
        guard !hybridLost else { return [] }
        hybridLost = true
        return [.hybridFallback(reason: reason)]
    }

    /// Draws `frame` when it applies on the screen the mirror holds and fits its grid;
    /// otherwise falls back (``DaemonTerminalInbound/hybridFallback(reason:)``).
    private mutating func accept(_ frame: AgentCLIHybridFrame, into out: inout [DaemonTerminalInbound]) {
        if let reason = frame.invalidReason {
            out += fallBack("frame \(frame.frame): \(reason)")
            return
        }
        if let base = frame.base {
            guard let shown = hybridShown, shown.stream == frame.stream, shown.frame == base else {
                out += fallBack("frame \(frame.frame) applies on \(base), the mirror shows \(hybridShown.map { "\($0.frame)" } ?? "none")")
                return
            }
            if drewHybridFrame, !(grid.map { $0.columns == frame.columns && $0.rows == frame.rows } ?? false) {
                out += fallBack("frame \(frame.frame) is for another grid")
                return
            }
        }
        draw(frame, into: &out)
        hybridShown = (frame.stream, frame.frame)
    }

    /// Draws an agent CLI frame (`agent-cli-frame` or `agent-cli-lean`) into the mirror as
    /// terminal bytes, so it looks as it does from the PTY.
    private mutating func draw(_ frame: AgentCLIHybridFrame, into out: inout [DaemonTerminalInbound]) {
        guard let bytes = frame.terminalBytes else { return }
        let sameGrid = grid.map { $0.columns == frame.columns && $0.rows == frame.rows } ?? false
        if !sameGrid || frame.base == nil {
            out.append(.columns(frame.columns))
            out.append(.rows(frame.rows))
        }
        grid = (frame.columns, frame.rows)
        // Frames carry cells, not the terminal's modes: the alternate screen and the input
        // modes (bracketed paste, cursor keys, mouse) come as `output` bytes, which the
        // detector follows, and a keyframe keeps them.
        if frame.base == nil {
            if !drewHybridFrame {
                out.append(.historyRowsOmitted(0))
                out.append(.alternateScreen(detector.isActive))
            } else if !sameGrid {
                // A keyframe after a resize: the screen starts over at the new grid, in the
                // modes the stream set (the reset clears them, and the daemon does not resend them).
                out.append(.resetMirror(alternate: detector.isActive))
                let restoring = detector.restoringBytes
                if !restoring.isEmpty { out.append(.output(restoring)) }
            }
            // A keyframe at the same grid (the program switched screens) clears and draws the
            // screen the mirror shows: no reset, so the scrollback stays.
        } else if !drewHybridFrame {
            // A resumed stream applies on the mirror as it was, on the screen it showed.
            detector = AlternateScreenDetector(active: resumeAlternate)
        }
        out.append(.output(bytes))
        out.append(.hybridFrame(stream: frame.stream, frame: frame.frame, resumed: frame.base != nil && !drewHybridFrame))
        drewHybridFrame = true
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
