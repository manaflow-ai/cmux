import CmuxNextCompat
public import CmuxNextDaemon
import Foundation

/// What a closing terminal runs, read before the close (SHORTCUT LATENCY SL-3, 2026-11-02): Cmd-W on a
/// terminal decides its close question in the key's own turn, so the tab leaves in the frame after the
/// key instead of after a daemon round trip (`TabCloseGuard`). As Chrome closes a tab at once unless its
/// page registered a `beforeunload` handler, which the browser knows before the key.
///
/// The focused pane's selected terminal is read (`process-info`) when it gets the focus and again each
/// time its shell reports a new prompt or a new command (OSC 133 through the daemon: `promptSinceMs`,
/// `commandSinceMs`). An answer counts only while that shell state is the one it was read in. A
/// program's start is a new command to the shell, so it ends the answer; a terminal whose shell
/// reports neither (no shell integration) has no answer, and its close asks the daemon as before.
/// What is left: a program started in the few milliseconds before the daemon's report of it reaches
/// the store; that close happens without the question, and its undo toast brings the terminal back.
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
    /// Reads under way, by the stamp they read in (one read per terminal and shell state).
    private var pending: [SurfaceID: Stamp] = [:]

    /// `tab`'s shell state, or nil when its shell reports no prompt and no command (nothing can tell a
    /// program's start apart, so no answer is fresh).
    public static func stamp(_ tab: TabModel) -> Stamp? {
        guard tab.promptSinceMs != nil || tab.commandSinceMs != nil else { return nil }
        return Stamp(prompt: tab.promptSinceMs, command: tab.commandSinceMs)
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
            guard let self else { return }
            if pending[surface] == stamp { pending[surface] = nil }
            // No answer in time is no answer: the close asks again.
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
