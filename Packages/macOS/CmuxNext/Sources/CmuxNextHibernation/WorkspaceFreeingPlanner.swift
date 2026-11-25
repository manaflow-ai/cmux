public import CmuxNextSettings
public import Foundation

/// Which terminals of hibernated workspaces end their shell, and when to look again
/// (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md, "Which terminal tabs free").
///
/// Pure: the App gathers one ``Terminal`` per terminal tab of a hibernated workspace and parks ``Plan/due``
/// through the daemon's `park-tabs` (the tab stays; showing it starts a new shell in the same folder under
/// the saved screen). A terminal frees only when every fact holds; an unknown fact keeps it running:
///
/// - the workspace is hibernated, not shown, not pinned and not kept awake;
/// - the shell sits at its prompt (OSC 133 A) with no command running, and printed nothing since; with
///   ``Policy/runningCommands`` `relaunch` a running command frees too (showing the tab types it again), and with
///   `never` one keeps every terminal of its workspace;
/// - no program reports a status in it (OSC 7501), and no client is attached; an agent TUI frees only when it is
///   ``Terminal/Agent/resumable`` and ``Policy/agents`` is on (showing the tab resumes the session);
/// - it is this Mac's terminal (never an ssh or Cloud machine's);
/// - the workspace and the prompt are both older than ``Policy/idleMinutes``.
///
/// ```swift
/// let plan = WorkspaceFreeingPlanner().plan(terminals, policy: .init(settings), now: Date())
/// host.park(plan.due)
/// ```
public nonisolated struct WorkspaceFreeingPlanner: Sendable {
    /// Creates a planner (it holds no state).
    public init() {}

    /// The settings the planner reads (`workspaces.freeing.*`).
    public nonisolated struct Policy: Equatable, Sendable {
        /// False: no terminal frees on its own.
        public var enabled: Bool
        /// Minutes without use before a terminal frees.
        public var idleMinutes: Double
        /// An idle agent TUI with a recorded session frees too (`workspaces.freeing.agents`).
        public var agents: Bool
        /// Whether a running command keeps its workspace's terminals (`never`) or ends with its shell (`relaunch`).
        public var runningCommands: WorkspaceFreeingRunningCommandsSetting

        /// - Parameters:
        ///   - enabled: off by default (it ends shell processes).
        ///   - idleMinutes: one day by default.
        ///   - agents: on by default (showing the tab resumes the session).
        ///   - runningCommands: `never` by default (ending a program the person started is not ours to do silently).
        public init(enabled: Bool = WorkspaceHibernationSettings.freeingEnabledDefault,
                    idleMinutes: Double = WorkspaceHibernationSettings.freeingIdleMinutesDefault,
                    agents: Bool = WorkspaceHibernationSettings.freeingAgentsDefault,
                    runningCommands: WorkspaceFreeingRunningCommandsSetting = WorkspaceHibernationSettings.freeingRunningCommandsDefault) {
            self.enabled = enabled
            self.idleMinutes = idleMinutes
            self.agents = agents
            self.runningCommands = runningCommands
        }

        /// The policy cmux.json's `workspaces.freeing.*` sets; nil (no settings yet) takes the defaults.
        public init(_ settings: WorkspaceHibernationSettings?) {
            let settings = settings ?? WorkspaceHibernationSettings()
            self.init(enabled: settings.freeingEnabled, idleMinutes: settings.freeingIdleMinutes, agents: settings.freeingAgents,
                      runningCommands: settings.freeingRunningCommands)
        }
    }

    /// One terminal tab of a workspace, and what keeps its shell running.
    public nonisolated struct Terminal: Hashable, Sendable {
        /// The Claude Code or Codex TUI that runs in a terminal, as far as freeing goes.
        public enum Agent: Hashable, Sendable {
            /// Idle (no turn, nothing waits on the person) with its session id recorded: showing the tab resumes it.
            case resumable
            /// It works, waits on the person, or has no recorded session: it keeps the terminal.
            case working
        }

        /// The tab's surface id (what `park-tabs` takes).
        public var surface: String
        /// The workspace that holds it.
        public var workspace: String
        /// The workspace's newest sign of use (shown, output, an agent update); nil counts as now.
        public var workspaceLastActive: Date?
        /// The workspace is hibernated (nothing of it is in app memory).
        public var hibernated: Bool
        /// The workspace is shown, pinned or kept awake.
        public var workspaceKept: Bool
        /// When the shell drew the prompt it sits at; nil: a command runs, or the shell sends no OSC 133.
        public var promptSince: Date?
        /// When the terminal last printed anything; nil: never.
        public var lastOutput: Date?
        /// A program reports a status in it (OSC 7501), an agent included.
        public var programReported: Bool
        /// A client holds an attach stream on it, as far as the caller knows. The daemon checks again when it parks:
        /// `park-tabs` leaves a terminal a client is attached to, or one `set-terminal-keep` keeps, running.
        public var attached: Bool
        /// It runs on this Mac (not an ssh or Cloud machine).
        public var local: Bool
        /// The shell already ended or the tab is already parked.
        public var ended: Bool
        /// The agent TUI that runs in it; nil: none.
        public var agent: Agent?
        /// When the command that runs now started; nil: none runs, or the shell sends no OSC 133.
        public var commandSince: Date?

        /// A nil `promptSince` keeps the terminal running; `hibernated` and `local` default to true and `attached` to
        /// false, which the daemon's own attach and keep check backs up.
        public init(surface: String, workspace: String, workspaceLastActive: Date?, hibernated: Bool = true,
                    workspaceKept: Bool = false, promptSince: Date? = nil, lastOutput: Date? = nil,
                    programReported: Bool = false, attached: Bool = false, local: Bool = true, ended: Bool = false,
                    agent: Agent? = nil, commandSince: Date? = nil) {
            self.surface = surface
            self.workspace = workspace
            self.workspaceLastActive = workspaceLastActive
            self.hibernated = hibernated
            self.workspaceKept = workspaceKept
            self.promptSince = promptSince
            self.lastOutput = lastOutput
            self.programReported = programReported
            self.attached = attached
            self.local = local
            self.ended = ended
            self.agent = agent
            self.commandSince = commandSince
        }

        /// A command of the person's (not an agent TUI) runs in it.
        var runsCommand: Bool { agent == nil && commandSince != nil }

        /// Whether a fact keeps it running whatever its age, under `policy`.
        func isKept(_ policy: Policy) -> Bool {
            if !hibernated || workspaceKept || attached || !local || ended { return true }
            if let agent { return !(policy.agents && agent == .resumable) }
            if programReported { return true }
            if runsCommand { return policy.runningCommands != .relaunch }
            return promptSince == nil
        }

        /// When it was last used: the newest of the workspace's use, the prompt, the running command's start and
        /// the last output.
        func lastUse(now: Date) -> Date {
            let prompt = agent == nil && commandSince == nil ? promptSince ?? now : promptSince
            return [workspaceLastActive ?? now, prompt, commandSince, lastOutput].compactMap(\.self).max() ?? now
        }
    }

    /// What frees now, and when the next one comes due.
    public nonisolated struct Plan: Equatable, Sendable {
        /// The surfaces to park now, the longest idle first.
        public var due: [String]
        /// When the next terminal comes due; nil when none will without a change.
        public var nextCheck: Date?

        /// - Parameters:
        ///   - due: the surfaces to park now.
        ///   - nextCheck: when to plan again.
        public init(due: [String] = [], nextCheck: Date? = nil) {
            self.due = due
            self.nextCheck = nextCheck
        }
    }

    /// The plan for `terminals` at `now`.
    public func plan(_ terminals: [Terminal], policy: Policy, now: Date) -> Plan {
        guard policy.enabled else { return Plan() }
        let idle = max(policy.idleMinutes, 1) * 60
        var due: [(String, Date)] = []
        var next: Date?
        // `never`: a command the person runs keeps its whole workspace awake, as a running workspace always did.
        let busy: Set<String> = policy.runningCommands == .relaunch ? [] : Set(terminals.filter(\.runsCommand).map(\.workspace))
        for terminal in terminals where !terminal.isKept(policy) && !busy.contains(terminal.workspace) {
            let used = terminal.lastUse(now: now)
            let deadline = used.addingTimeInterval(idle)
            if deadline <= now {
                due.append((terminal.surface, used))
            } else if next.map({ deadline < $0 }) ?? true {
                next = deadline
            }
        }
        let floor = now.addingTimeInterval(WorkspaceHibernationPlanner.minimumRecheck)
        return Plan(due: due.sorted { $0.1 < $1.1 }.map(\.0), nextCheck: next.map { max($0, floor) })
    }
}
