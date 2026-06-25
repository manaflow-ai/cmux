import Foundation

/// MainActor glue that periodically compares the live process-detection and
/// hook-session indexes and warns (once per pane/session) when an agent is
/// running untracked. The decision policy lives in `UntrackedAgentSessionDetector`;
/// this type owns only the per-pane state (first-seen-without-hook timestamps,
/// dedupe) and the index reads + delivery.
///
/// `evaluate(detectedAgents:hasHookSession:now:)` is the unit-testable core: it
/// takes already-resolved inputs (the detected agents, a hook-present lookup, and
/// the clock) so the warn-once / grace / reset behavior is provable without the
/// live process capture. `refresh()` is the thin real tick that captures the
/// process snapshot off-main and feeds `evaluate` on main.
@MainActor
final class UntrackedAgentSessionMonitor {
    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    /// A live agent process detected in a pane.
    struct DetectedAgent: Equatable, Sendable {
        var kind: RestorableAgentKind
        /// A stable per-session identity used for warn-once dedupe and to detect
        /// when a pane's agent has been replaced by a new session. For live
        /// detection this is the agent process pid (a relaunch is a new pid, so a
        /// later bypassed session re-warns); tests pass any stable token.
        var identity: String
    }

    private struct PaneWarnState {
        var identity: String
        var firstSeenWithoutHook: TimeInterval
        var warned: Bool
    }

    private let detector: UntrackedAgentSessionDetector
    private let warningEnabled: () -> Bool
    private let deliver: (PanelKey, RestorableAgentKind) -> Void

    /// Per-pane state for panes currently detected without a hook session. Pruned
    /// when the pane gains a hook session or its agent process disappears, so a
    /// later genuine bypass in the same pane warns again.
    private var paneState: [PanelKey: PaneWarnState] = [:]

    /// Repeating background check timer (nil when not started).
    private var pollTimer: Timer?

    init(
        detector: UntrackedAgentSessionDetector = UntrackedAgentSessionDetector(),
        warningEnabled: @escaping () -> Bool = { UntrackedAgentSessionWarningSettings.isEnabled() },
        deliver: @escaping (PanelKey, RestorableAgentKind) -> Void
    ) {
        self.detector = detector
        self.warningEnabled = warningEnabled
        self.deliver = deliver
    }

    /// Pure-over-inputs evaluation. For each detected agent pane: a hook-proven
    /// session clears state; otherwise the pane is tracked as detected-without-hook
    /// (resetting the clock when the session id changes — a new bypassed session),
    /// the detector decides, and a warn is delivered at most once per pane/session.
    func evaluate(
        detectedAgents: [PanelKey: DetectedAgent],
        hasHookSession: (PanelKey) -> Bool,
        now: TimeInterval
    ) {
        // Drop state for panes whose agent process is gone.
        paneState = paneState.filter { detectedAgents[$0.key] != nil }

        let enabled = warningEnabled()

        for (key, agent) in detectedAgents {
            if hasHookSession(key) {
                // Tracked — the happy path. Clear any pending bypass state.
                paneState[key] = nil
                continue
            }

            // Untracked: start (or continue) the without-hook clock for this
            // session. A changed identity in the same pane is a new session, so
            // the clock and dedupe reset.
            var state = paneState[key]
            if state == nil || state?.identity != agent.identity {
                state = PaneWarnState(identity: agent.identity, firstSeenWithoutHook: now, warned: false)
            }

            let facts = PaneTrackingFacts(
                agentKind: agent.kind,
                hasProcessDetectedAgent: true,
                hasHookProvenSession: false,
                secondsDetectedWithoutHook: now - (state?.firstSeenWithoutHook ?? now),
                alreadyWarned: state?.warned ?? false,
                warningEnabled: enabled
            )

            if detector.decide(facts) == .warn {
                deliver(key, agent.kind)
                state?.warned = true
            }
            paneState[key] = state
        }
    }

    /// The agent kind for a process whose executable basename names a hook-tracked
    /// agent (Claude/Codex), or nil. Claude/Codex are NOT in the vault
    /// process-detection registry (that only emits custom/opencode kinds) and are
    /// otherwise known to cmux only through their hook store — the tracked path. So
    /// a *bypassed* claude/codex is invisible except as a raw process; detecting it
    /// by executable name is the only signal for "running but untracked".
    nonisolated static func supportedAgentKind(processName name: String, path: String?) -> RestorableAgentKind? {
        let basename = ((path?.isEmpty == false ? path! : name) as NSString).lastPathComponent.lowercased()
        switch basename {
        case "claude": return .claude
        case "codex": return .codex
        default: return nil
        }
    }

    /// Real tick: capture the process snapshot off-main (sysctl/top must not block
    /// the main thread), find cmux-scoped Claude/Codex processes by executable
    /// name, then evaluate on main using the cached, non-blocking hook lookup.
    func refresh() {
        Task.detached(priority: .utility) {
            let snapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
            // One agent process per pane (lowest pid is the stable identity).
            var byPane: [PanelKey: (kind: RestorableAgentKind, pid: Int)] = [:]
            for process in snapshot.cmuxScopedProcesses() {
                guard let workspaceId = process.cmuxWorkspaceID,
                      let surfaceId = process.cmuxSurfaceID,
                      let kind = Self.supportedAgentKind(processName: process.name, path: process.path) else {
                    continue
                }
                let key = PanelKey(workspaceId: workspaceId, panelId: surfaceId)
                if let existing = byPane[key], existing.pid <= process.pid { continue }
                byPane[key] = (kind, process.pid)
            }
            let agents: [PanelKey: DetectedAgent] = byPane.mapValues {
                DetectedAgent(kind: $0.kind, identity: String($0.pid))
            }
            await MainActor.run {
                self.evaluate(
                    detectedAgents: agents,
                    hasHookSession: { key in
                        SharedLiveAgentIndex.shared.snapshot(workspaceId: key.workspaceId, panelId: key.panelId) != nil
                    },
                    now: Date().timeIntervalSince1970
                )
            }
        }
    }

    /// Test seam: panes currently tracked as detected-without-hook.
    var trackedPaneCountForTesting: Int { paneState.count }
}

extension UntrackedAgentSessionMonitor {
    /// The app-wide monitor, wired to deliver the warning through the terminal
    /// notification store. Started once at launch (see `AppDelegate`).
    static let shared = UntrackedAgentSessionMonitor(deliver: deliverWarning)

    private static func deliverWarning(_ key: PanelKey, _ kind: RestorableAgentKind) {
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: key.workspaceId,
            surfaceId: key.panelId,
            title: String(
                localized: "agentTracking.untracked.title",
                defaultValue: "Session not tracked"
            ),
            subtitle: "",
            body: String(
                localized: "agentTracking.untracked.body",
                defaultValue: "This agent session isn't being recorded by cmux, so this window won't resume after a crash or update. The agent was launched outside cmux's wrapper (a custom launcher, alias, or PATH order can cause this)."
            ),
            // Belt-and-suspenders dedupe in addition to the per-pane warn-once:
            // never re-warn the same pane within an hour even across restarts.
            cooldownKey: "untracked-agent-session.\(key.workspaceId.uuidString).\(key.panelId.uuidString)",
            cooldownInterval: 3600
        )
    }

    /// Begin the periodic check. Idempotent. The interval is coarse — this is a
    /// background safety check, not a hot path.
    func start(interval: TimeInterval = 7) {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        pollTimer = timer
        refresh()
    }

    /// Stop the periodic check.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
