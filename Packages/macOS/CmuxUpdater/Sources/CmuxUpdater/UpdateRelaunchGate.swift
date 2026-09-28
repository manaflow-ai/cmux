/// How safely an agent session survives an update relaunch, as the host classifies it.
public enum UpdateResumeSafety: String, Equatable, Sendable {
    /// Idle, waiting for input, or between tool calls. Resumes with no loss.
    case safe
    /// A model request in flight, or waiting on a background task or subagent. Resumes and
    /// re-issues the work.
    case care
    /// A foreground command is running under it (a build, a test, ssh, a long wait loop), or a
    /// permission prompt or question is unanswered. A relaunch would cut that off.
    case risky
}

/// One agent session as an update relaunch would find it.
public struct UpdateRelaunchAgent: Equatable, Sendable, Identifiable {
    /// A stable id for the session's pane.
    public var id: String
    /// The agent's display name, such as "Claude Code".
    public var name: String
    /// Where it runs, such as its workspace title.
    public var location: String
    public var safety: UpdateResumeSafety
    /// What it is doing, such as "Bash: swift build" or "Thinking".
    public var activity: String

    /// Creates an agent entry.
    public init(id: String, name: String, location: String, safety: UpdateResumeSafety, activity: String) {
        self.id = id
        self.name = name
        self.location = location
        self.safety = safety
        self.activity = activity
    }
}

/// What an update relaunch would interrupt right now, as reported by the host app.
public struct UpdateRelaunchBlockers: Equatable, Sendable {
    /// Every live agent session, with how safely it resumes.
    public var agents: [UpdateRelaunchAgent]
    /// Other foreground commands in local terminals (a dev server, a build). Relaunching would
    /// stop them for good.
    public var runningCommandCount: Int

    /// Nothing would be interrupted.
    public static let empty = UpdateRelaunchBlockers(agents: [], runningCommandCount: 0)

    /// Creates a blocker report.
    public init(agents: [UpdateRelaunchAgent], runningCommandCount: Int) {
        self.agents = agents
        self.runningCommandCount = runningCommandCount
    }

    /// Agents a relaunch would cut off mid-command or mid-question.
    public var riskyAgents: [UpdateRelaunchAgent] { agents.filter { $0.safety == .risky } }
    /// Agents that resume mid-task and re-issue their work.
    public var careAgents: [UpdateRelaunchAgent] { agents.filter { $0.safety == .care } }

    /// Whether relaunching now needs the user's say-so: a risky agent or a running command.
    /// Safe and care agents resume on their own.
    public var needsConfirmation: Bool {
        !riskyAgents.isEmpty || runningCommandCount > 0
    }
}

/// Holds an update relaunch until relaunching is safe or the user decides.
///
/// Nothing here depends on a perfect idle signal. The host classifies every agent session
/// (``UpdateResumeSafety``): safe and care agents are resumed after the relaunch, so only risky
/// agents and other running commands hold it. The gate has three modes:
///
/// - ``Mode/quietMoment``: an automatic install. It relaunches when nothing is risky and nobody
///   has touched the keyboard or mouse for ``quietPeriod``. There is no timeout; until then the
///   pill offers Install Now, and quitting cmux still installs the update.
/// - ``Mode/askUser``: the user asked to install while something is risky. The popover lists
///   the agents and offers Wait, Update When These Finish, and Update Anyway. It never
///   relaunches on its own.
/// - ``Mode/whenClear``: the user chose Update When These Finish. It relaunches as soon as
///   nothing is risky.
///
/// Before relaunching on its own, the gate asks the host to prepare (a fresh session capture,
/// so every agent is saved with its resume binding), then checks again, because an agent can
/// start a command or the user can come back while the capture runs.
///
/// While holding, the gate publishes ``UpdateState/installing(_:)`` carrying the current
/// ``UpdateRelaunchBlockers``. Install Now / Update Anyway and Later / Wait are that state's
/// `retryTerminatingApplication` and `dismiss` actions; Update When These Finish is
/// `updateWhenClear`.
@MainActor
final class UpdateRelaunchGate {
    /// How often a holding gate re-reads the host's blockers and input idle time.
    static let recheckInterval: Duration = .seconds(2)
    /// How long the keyboard and mouse must be untouched before an automatic relaunch.
    static let quietPeriod: Duration = .seconds(60)

    /// What a hold waits for.
    enum Mode: Equatable {
        case quietMoment
        case askUser
        case whenClear
    }

    private let clock: any UpdateClock
    private let log: any UpdateLogging
    private let recheckInterval: Duration
    private let quietPeriod: Duration
    private var waitTask: Task<Void, Never>?
    private var pending: Pending?

    /// What the gate reads from the host on every check.
    struct Readiness: Equatable {
        var blockers: UpdateRelaunchBlockers
        var idle: Duration
    }

    private final class Pending {
        var mode: Mode
        let relaunch: () -> Void
        let later: () -> Void
        var published: (UpdateRelaunchBlockers, Mode)?
        var isPreparing = false
        var installNowRequested = false

        init(mode: Mode, relaunch: @escaping () -> Void, later: @escaping () -> Void) {
            self.mode = mode
            self.relaunch = relaunch
            self.later = later
        }
    }

    init(
        clock: any UpdateClock,
        log: any UpdateLogging,
        recheckInterval: Duration = UpdateRelaunchGate.recheckInterval,
        quietPeriod: Duration = UpdateRelaunchGate.quietPeriod
    ) {
        self.clock = clock
        self.log = log
        self.recheckInterval = recheckInterval
        self.quietPeriod = quietPeriod
    }

    deinit {
        waitTask?.cancel()
    }

    /// Whether a relaunch is currently held.
    var isWaiting: Bool { pending != nil }

    /// The current hold's mode, if any.
    var mode: Mode? { pending?.mode }

    /// Whether a hold in `mode` may relaunch on its own now.
    nonisolated static func mayRelaunch(_ readiness: Readiness, mode: Mode, quietPeriod: Duration) -> Bool {
        switch mode {
        case .askUser:
            return false
        case .whenClear:
            return !readiness.blockers.needsConfirmation
        case .quietMoment:
            return !readiness.blockers.needsConfirmation && readiness.idle >= quietPeriod
        }
    }

    /// Publishes a holding state through `publish` and relaunches when `mode` allows it (see
    /// the type's discussion), running `prepare` first. Install Now runs `prepare` and
    /// `relaunch` without waiting; Later runs `later` instead. Each hold runs at most one of
    /// `relaunch` or `later`: a new hold defers the old one, and ``cancel()`` (the update
    /// session ended) runs neither. `isShown` reports whether the published state is still the
    /// visible one; once something else replaced it, the hold ends without touching the newer
    /// state.
    func hold(
        mode: Mode,
        readiness: @escaping @MainActor () -> Readiness,
        isShown: @escaping @MainActor () -> Bool,
        publish: @escaping @MainActor (UpdateState) -> Void,
        prepare: @escaping @MainActor () async -> Void,
        relaunch: @escaping () -> Void,
        later: @escaping () -> Void
    ) {
        if let previous = pending {
            finish(previous, relaunching: false)
        }
        let request = Pending(mode: mode, relaunch: relaunch, later: later)
        pending = request
        log.append("update relaunch held (mode=\(mode))")
        let actions = Actions(publish: publish, prepare: prepare)
        publishHold(request, blockers: readiness().blockers, actions: actions)
        let interval = recheckInterval
        waitTask = Task { @MainActor [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, self.pending === request else { return }
                guard isShown() else {
                    self.log.append("update relaunch gate: held state replaced; ending hold")
                    self.cancel()
                    return
                }
                let current = readiness()
                guard Self.mayRelaunch(current, mode: request.mode, quietPeriod: self.quietPeriod) else {
                    self.publishHold(request, blockers: current.blockers, actions: actions)
                    continue
                }
                self.log.append("update relaunch gate: clear to relaunch; preparing")
                request.isPreparing = true
                await prepare()
                request.isPreparing = false
                guard self.pending === request else { return }
                // The capture takes a moment: an agent may have started a command, or the user
                // may be back. Relaunch only if it is still clear.
                let after = readiness()
                if request.installNowRequested
                    || Self.mayRelaunch(after, mode: request.mode, quietPeriod: self.quietPeriod) {
                    self.log.append("update relaunch gate: relaunching")
                    self.finish(request, relaunching: true)
                    return
                }
                self.log.append(
                    "update relaunch gate: activity during prepare (risky=\(after.blockers.riskyAgents.count), commands=\(after.blockers.runningCommandCount)); holding again"
                )
                self.publishHold(request, blockers: after.blockers, actions: actions)
            }
        }
    }

    private struct Actions {
        let publish: @MainActor (UpdateState) -> Void
        let prepare: @MainActor () async -> Void
    }

    private func publishHold(_ request: Pending, blockers current: UpdateRelaunchBlockers, actions: Actions) {
        if let published = request.published, published.0 == current, published.1 == request.mode { return }
        request.published = (current, request.mode)
        actions.publish(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self, weak request] in
                guard let self, let request, self.pending === request else { return }
                self.log.append("update relaunch gate: install now")
                guard !request.isPreparing else {
                    // A capture for a clear moment is already running; relaunch when it ends.
                    request.installNowRequested = true
                    return
                }
                self.waitTask?.cancel()
                self.waitTask = nil
                request.isPreparing = true
                Task { @MainActor [weak self] in
                    await actions.prepare()
                    self?.finish(request, relaunching: true)
                }
            },
            dismiss: { [weak self, weak request] in
                guard let self, let request else { return }
                self.log.append("update relaunch gate: later")
                self.finish(request, relaunching: false)
            },
            relaunchBlockers: current,
            updateWhenClear: request.mode == .askUser ? { [weak self, weak request] in
                guard let self, let request, self.pending === request else { return }
                self.log.append("update relaunch gate: update when these finish")
                request.mode = .whenClear
                self.publishHold(request, blockers: current, actions: actions)
            } : nil
        )))
    }

    /// Ends a held relaunch without running either action, because the update session that
    /// owned it ended (an error, a finished cycle, or a completed install).
    func cancel() {
        guard pending != nil else { return }
        pending = nil
        waitTask?.cancel()
        waitTask = nil
    }

    private func finish(_ request: Pending, relaunching: Bool) {
        guard pending === request else { return }
        pending = nil
        waitTask?.cancel()
        waitTask = nil
        if relaunching {
            request.relaunch()
        } else {
            request.later()
        }
    }
}
