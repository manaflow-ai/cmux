import CmuxNextCompat
import CmuxNextDaemon
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

    public init() {}

    /// Keeps the focused terminal read: `focused` is the active window's focused pane's selected tab and its daemon,
    /// observed (one tab, never the session); each focus change and each new prompt or command of it reads it again.
    /// Ends at the first change after `ended` answers true (its owner is gone).
    public func follow(focused: @escaping @MainActor @Sendable () -> (tab: TabModel, daemon: DaemonService)?,
                       ended: @escaping @MainActor @Sendable () -> Bool) {
        // task-owner: the app's lifetime; ends with the services that own `focused`.
        Task { [weak self] in
            let focus = ObservationStream { () -> Focus? in
                guard let tab = focused()?.tab, tab.isLiveTerminal else { return nil }
                return Focus(surface: tab.surface, stamp: Self.stamp(tab))
            }
            var last: Focus?
            for await now in focus where now != last {
                last = now
                guard let self, !ended() else { return }
                guard now?.stamp != nil, let current = focused(), current.tab.surface == now?.surface else { continue }
                prepare(current.tab, on: current.daemon)
            }
        }
    }

    private struct Focus: Equatable, Sendable {
        var surface: SurfaceID
        var stamp: Stamp?
    }
}
