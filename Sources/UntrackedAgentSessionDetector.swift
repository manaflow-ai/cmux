import Foundation

/// The per-pane facts that decide whether cmux should warn the user that an
/// agent session is running untracked (its hooks were bypassed, so it won't
/// resume after a crash/update).
///
/// A plain value type with no app or filesystem coupling so the decision is
/// exhaustively unit-testable. The MainActor monitor builds these facts from the
/// live process-detection and hook-session indexes; the detector itself reads
/// nothing.
struct PaneTrackingFacts: Equatable, Sendable {
    /// The agent kind detected running in the pane, if any.
    var agentKind: RestorableAgentKind?
    /// A live agent process was detected in this pane (e.g. `claude`).
    var hasProcessDetectedAgent: Bool
    /// cmux has a hook-proven session recorded for this pane (SessionStart
    /// fired). When true the session IS tracked and resumable — no warning.
    var hasHookProvenSession: Bool
    /// How long the agent process has been continuously detected in this pane
    /// *without* a hook-proven session. The grace window keys off this so a
    /// session that simply hasn't fired SessionStart yet is not flagged.
    var secondsDetectedWithoutHook: TimeInterval
    /// This pane/session has already been warned about (dedupe).
    var alreadyWarned: Bool
    /// The user-facing warning is enabled (opt-out, default on).
    var warningEnabled: Bool

    init(
        agentKind: RestorableAgentKind?,
        hasProcessDetectedAgent: Bool,
        hasHookProvenSession: Bool,
        secondsDetectedWithoutHook: TimeInterval,
        alreadyWarned: Bool,
        warningEnabled: Bool
    ) {
        self.agentKind = agentKind
        self.hasProcessDetectedAgent = hasProcessDetectedAgent
        self.hasHookProvenSession = hasHookProvenSession
        self.secondsDetectedWithoutHook = secondsDetectedWithoutHook
        self.alreadyWarned = alreadyWarned
        self.warningEnabled = warningEnabled
    }
}

/// Why a pane is NOT warned. Stable raw form for logging and tests.
enum UntrackedSessionSkipReason: Hashable, Sendable {
    /// The opt-out setting is off.
    case disabled
    /// No agent process is detected in the pane.
    case noAgent
    /// A hook-proven session exists — the pane IS tracked.
    case tracked
    /// The agent kind is outside the set whose hooks cmux injects (Claude/Codex).
    case unsupported(RestorableAgentKind)
    /// The agent was detected too recently without a hook to distinguish a real
    /// bypass from SessionStart latency.
    case withinGrace
    /// This pane/session was already warned once.
    case alreadyWarned
}

/// The outcome of evaluating a pane.
enum UntrackedSessionWarnDecision: Equatable, Sendable {
    /// Warn the user once: this pane has a live agent that cmux is not tracking.
    case warn
    /// Do not warn; `reason` records why.
    case skip(UntrackedSessionSkipReason)
}

/// Pure decision core for the "your agent session isn't being tracked" warning.
///
/// cmux records an agent session only when its `claude` wrapper shim injects the
/// hook `--settings`. A custom launcher, alias, shell function, or PATH ordering
/// that reaches the raw binary silently skips that injection — no SessionStart,
/// no recorded session, no resume after a crash/update, and no feedback. This
/// detector flags exactly that state: a live agent process in a pane with no
/// hook-proven session, after a grace window, once.
///
/// Side-effect free by construction; the single `decide` entry mirrors the
/// project's other pure policy types so the full warn/skip matrix is testable
/// without the app host.
struct UntrackedAgentSessionDetector {
    /// How long an agent may be detected without a hook session before it counts
    /// as a genuine bypass (vs. SessionStart not having fired yet).
    var graceInterval: TimeInterval

    init(graceInterval: TimeInterval = 10) {
        self.graceInterval = graceInterval
    }

    /// Agent kinds whose sessions cmux tracks via injected hooks. Outside this
    /// set there is nothing to be untracked *relative to*, so no warning.
    static func isSupported(_ kind: RestorableAgentKind) -> Bool {
        switch kind {
        case .claude, .codex: return true
        default: return false
        }
    }

    func decide(_ facts: PaneTrackingFacts) -> UntrackedSessionWarnDecision {
        // 1. Respect the opt-out before anything else.
        guard facts.warningEnabled else { return .skip(.disabled) }

        // 2. Nothing to warn about without a live agent process.
        guard facts.hasProcessDetectedAgent, let kind = facts.agentKind else {
            return .skip(.noAgent)
        }

        // 3. A hook-proven session means the pane IS tracked — the happy path.
        guard !facts.hasHookProvenSession else { return .skip(.tracked) }

        // 4. Only agents whose hooks cmux injects can be "untracked".
        guard Self.isSupported(kind) else { return .skip(.unsupported(kind)) }

        // 5. A freshly-detected agent may simply not have fired SessionStart yet;
        //    wait out the grace window before calling it a bypass.
        guard facts.secondsDetectedWithoutHook >= graceInterval else {
            return .skip(.withinGrace)
        }

        // 6. Warn at most once per pane/session.
        guard !facts.alreadyWarned else { return .skip(.alreadyWarned) }

        return .warn
    }

    /// Convenience: whether these facts warrant a warning right now.
    func shouldWarn(_ facts: PaneTrackingFacts) -> Bool {
        decide(facts) == .warn
    }
}
