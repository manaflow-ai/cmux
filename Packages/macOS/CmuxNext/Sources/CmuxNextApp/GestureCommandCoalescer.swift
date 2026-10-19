import CmuxNextLayout

/// Sends a divider or column drag's daemon commands with at most one in
/// flight per gesture (Lawrence 2026-10-18: "insanely laggy", an error moving
/// panes). A drag reports a new value on every mouse move; each value was its
/// own `set-viewport-pane-width` / `set-split-ratio` round-trip (about 125 a
/// second in NIGHTLY's log), so the daemon fell seconds behind and every
/// other command (tab and pane moves, saves, attaches) timed out at its 2 s
/// deadline. The layout shows each value at once from its own override; the
/// daemon only needs the newest one: while a command runs, a newer value
/// replaces the one waiting, and a gesture's `.ended` value always goes last.
@MainActor final class GestureCommandCoalescer {
    /// Runs one command; true when the daemon applied it.
    typealias Run = @MainActor (_ label: String, _ body: @escaping DaemonCommandBody) async -> Bool
    /// One command's outcome. `superseded`: a newer value of the same gesture
    /// is waiting to be sent, so a failed live value needs no rollback.
    typealias Finished = @MainActor (_ ok: Bool, _ superseded: Bool) -> Void

    private struct Command {
        var label: String
        var phase: LayoutGesturePhase
        var body: DaemonCommandBody
        var finished: Finished
    }

    private struct Lane {
        var waiting: Command?
    }

    private let run: Run
    /// The gestures with a command in flight, and the newest value each one waits to send.
    private var lanes: [LayoutTransactionID: Lane] = [:]

    /// The commands sent so far (sent, not submitted); for tests and `debug` counters.
    private(set) var sent = 0

    /// - Parameter run: sends one command (the app passes `DaemonService.run`).
    init(run: @escaping Run) {
        self.run = run
    }

    /// Sends `body` for `transaction`'s gesture now, or, while an earlier one
    /// of the gesture is in flight, after it in place of any value still waiting.
    /// A waiting `.ended` value is never replaced (nothing comes after it).
    func submit(_ transaction: LayoutTransactionID, phase: LayoutGesturePhase, label: String,
                _ body: @escaping DaemonCommandBody, finished: @escaping Finished) {
        let command = Command(label: label, phase: phase, body: body, finished: finished)
        if var lane = lanes[transaction] {
            if lane.waiting?.phase == .ended, phase != .ended { return }
            lane.waiting = command
            lanes[transaction] = lane
            return
        }
        lanes[transaction] = Lane()
        start(command, transaction)
    }

    /// Whether `transaction`'s gesture has a command in flight.
    func isBusy(_ transaction: LayoutTransactionID) -> Bool { lanes[transaction] != nil }

    private func start(_ command: Command, _ transaction: LayoutTransactionID) {
        sent += 1
        Task { @MainActor in
            let ok = await run(command.label, command.body)
            let next = lanes[transaction]?.waiting
            command.finished(ok, next != nil)
            if let next {
                lanes[transaction]?.waiting = nil
                start(next, transaction)
            } else {
                lanes[transaction] = nil
            }
        }
    }
}
