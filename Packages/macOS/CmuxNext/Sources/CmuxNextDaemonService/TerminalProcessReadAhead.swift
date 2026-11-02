import CmuxNextCompat
public import CmuxNextDaemon
import Foundation

/// What a closing terminal runs, read before the close (SHORTCUT LATENCY SL-3, 2026-11-02): Cmd-W on a
/// terminal decides its close question in the key's own turn, so the tab leaves in the frame after the
/// key instead of after a daemon round trip (`TabCloseGuard`). As Chrome closes a tab at once unless its
/// page registered a `beforeunload` handler, which the browser knows before the key.
///
/// The focused pane's selected terminal is read (`process-info`) when it gets the focus and again each
/// time its shell reports a new prompt (OSC 133 through the daemon: `promptSinceMs`). Only a terminal at
/// its prompt is read, and an answer counts only while the shell sits at that same prompt: a command's
/// start (`commandSinceMs`) ends it. A command's own state is never read ahead: between the shell's
/// OSC 133 C and the command's exec a read still sees the shell, and that "no program" would hold for the
/// whole run (review of #31875). A terminal with no prompt report (no shell integration, a command
/// running) has no answer, and its close asks the daemon at the key as before.
/// What is left: a command started in the few milliseconds before the daemon's report of it reaches the
/// store closes without the question and without an undo toast (Reopen Closed brings it back).
@MainActor
public final class TerminalProcessReadAhead {
    /// The shell state an answer was read in.
    public struct Stamp: Equatable, Sendable {
        public var prompt: UInt64?
        public var command: UInt64?
    }

    private struct Answer {
        var program: String?
        var stamp: Stamp
    }

    /// The most terminals an answer is kept for: the focused one and the few focused before it.
    public static let capacity = 16
    private var answers: [SurfaceID: Answer] = [:]
    /// The newest prompt each terminal was read at; an older read that answers late is dropped.
    private var pending: [SurfaceID: Stamp] = [:]

    /// `tab`'s prompt, or nil unless its shell reports it sits at its prompt with no command running: only
    /// that state is read ahead and only an answer read in it counts.
    public static func stamp(_ tab: TabModel) -> Stamp? {
        guard let prompt = tab.promptSinceMs, tab.commandSinceMs == nil else { return nil }
        return Stamp(prompt: prompt, command: nil)
    }

    /// Each of `tabs`' foreground program as read in its current shell state, or nil when any has no
    /// such answer (the close then asks the daemon).
    public func fresh(_ tabs: [TabModel]) -> RunningPrograms? {
        var programs: RunningPrograms = [:]
        for tab in tabs {
            guard let stamp = Self.stamp(tab), let answer = answers[tab.surface], answer.stamp == stamp else { return nil }
            programs[tab.surface] = .some(answer.program)
        }
        return programs
    }

    /// Reads `tab`'s foreground program unless an answer for its current shell state is known or on its
    /// way. The read waits on no thread (an awaited daemon request); the answer is kept when it comes.
    public func prepare(_ tab: TabModel, on daemon: DaemonService) {
        guard tab.isLiveTerminal, let stamp = Self.stamp(tab), answers[tab.surface]?.stamp != stamp,
              pending[tab.surface] != stamp, let connection = daemon.connection else { return }
        let surface = tab.surface
        pending[surface] = stamp
        // task-owner: one bounded process-info read (1 s); its answer is kept for the next close of this terminal.
        Task { [weak self] in
            let response = await connection.readProcessInfo(surface, timeout: .seconds(1))
            // A read for an older prompt answers nothing (a newer one was asked since); no answer in time is no
            // answer, and the close asks at the key.
            guard let self, pending[surface] == stamp else { return }
            pending[surface] = nil
            guard let response else { return }
            if answers[surface] == nil, answers.count >= Self.capacity { answers.removeAll(keepingCapacity: true) }
            answers[surface] = Answer(program: response.runningProgram, stamp: stamp)
        }
    }

    /// The focused terminal's watch: its shell state, observed while it has the focus.
    private var watch: Task<Void, Never>?
    private var watched: SurfaceID?

    public init() {}

    /// The focus moved to `tab` of `daemon` (nil: no terminal has it). The focused terminal is read now and again at
    /// each new prompt or command its shell reports, while it has the focus: one observed tab, never the session.
    public func focus(_ tab: TabModel?, on daemon: DaemonService?) {
        guard let tab, tab.isLiveTerminal, let daemon else {
            watch?.cancel()
            (watch, watched) = (nil, nil)
            return
        }
        guard watched != tab.surface else { return }
        watch?.cancel()
        watched = tab.surface
        prepare(tab, on: daemon)
        // task-owner: cancelled at the next focus change; the stream then returns nil.
        watch = Task { [weak self, weak tab, weak daemon] in
            for await _ in ObservationStream({ [weak tab] in tab.flatMap(Self.stamp) }) {
                guard !Task.isCancelled, let self, let tab, let daemon else { return }
                prepare(tab, on: daemon)
            }
        }
    }
}
