public import AppKit
import CmuxNextTerminalGeometry
import CmuxNextWakeups

#if DEBUG || CMUX_BENCH_HOOKS
/// When a split's or a close's terminals reach their final grid (`debug.terminal_final_grid`,
/// scripts/cmux-next/bench-terminal-resize.py `split-resize`; Lawrence 2026-10-23: Cmd-D and Cmd-W must
/// resize the program in the terminal before the animation ends). DEBUG builds only.
///
/// ``start()`` records the time; the bench runs the split or close right after it. Until ``stop()`` every
/// grid sent to the PTY owner is recorded (``noteSend(_:columns:rows:)``), and on every display frame each
/// terminal in a window reports the grid Ghostty's last frame drew and the owner's grid (the owner
/// announced it: the PTY has it and the program got its SIGWINCH).
@MainActor
public final class TerminalFinalGridTrace {
    /// One recorded grid, `ms` after ``start()``; `grid` is "COLUMNSxROWS".
    public nonisolated struct Mark: Sendable {
        public var ms: Double
        public var grid: String
    }

    /// One terminal's marks: grids sent, drawn and announced (changes only), and its view's grid at ``stop()``.
    public nonisolated struct Terminal: Sendable {
        public var sends: [Mark] = []
        public var drawn: [Mark] = []
        public var owner: [Mark] = []
        public var fitted: String?
    }

    /// A shown terminal: its key, its session, and its PTY owner's identity (what ``noteSend(_:columns:rows:)`` names).
    public typealias Entry = (key: String, session: TerminalSession, owner: ObjectIdentifier)

    private let terminals: @MainActor () -> [Entry]
    private var startedAt: CFTimeInterval = 0
    private var active = false
    private var sends: [ObjectIdentifier: [Mark]] = [:]
    private var marks: [String: Terminal] = [:]
    private var last: [String: (drawn: TerminalGridSize?, owner: TerminalGridSize?)] = [:]
    private lazy var frames = FrameClient(owner: "TerminalFinalGridTrace", isAnimation: false, on: .app) { [weak self] _ in
        self?.sample() ?? false
    }

    /// - Parameter terminals: The app's live terminals (the content cache's).
    public init(terminals: @escaping @MainActor () -> [Entry]) {
        self.terminals = terminals
    }

    /// Clears the trace and starts recording.
    public func start() {
        (sends, marks, last) = ([:], [:], [:])
        startedAt = CACurrentMediaTime()
        active = true
        _ = sample()
        frames.activate()
    }

    /// A grid went to the PTY owner `owner`.
    public func noteSend(_ owner: ObjectIdentifier, columns: Int, rows: Int) {
        guard active else { return }
        sends[owner, default: []].append(Mark(ms: now, grid: "\(columns)x\(rows)"))
    }

    /// Stops recording; every shown terminal's marks by key.
    public func stop() -> [String: Terminal] {
        active = false
        var result: [String: Terminal] = [:]
        for entry in terminals() where entry.session.view.window != nil {
            var terminal = marks[entry.key] ?? Terminal()
            terminal.sends = sends[entry.owner] ?? []
            terminal.fitted = entry.session.diagnostics.fitGrid.map { "\($0.columns)x\($0.rows)" }
            result[entry.key] = terminal
        }
        return result
    }

    private var now: Double { ((CACurrentMediaTime() - startedAt) * 1_000 * 100).rounded() / 100 }

    private func sample() -> Bool {
        guard active else { return false }
        let t = now
        for entry in terminals() where entry.session.view.window != nil {
            let grids = entry.session.drawnAndOwnerGrid
            let previous = last[entry.key]
            if previous?.drawn != grids.drawn, let grid = grids.drawn {
                marks[entry.key, default: Terminal()].drawn.append(Mark(ms: t, grid: "\(grid.columns)x\(grid.rows)"))
            }
            if previous?.owner != grids.owner, let grid = grids.owner {
                marks[entry.key, default: Terminal()].owner.append(Mark(ms: t, grid: "\(grid.columns)x\(grid.rows)"))
            }
            last[entry.key] = grids
        }
        return true
    }
}
#endif
