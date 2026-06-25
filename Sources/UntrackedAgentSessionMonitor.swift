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
        var sessionId: String
    }

    private struct PaneWarnState {
        var sessionId: String
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
            // session. A changed session id in the same pane is a new session, so
            // the clock and dedupe reset.
            var state = paneState[key]
            if state == nil || state?.sessionId != agent.sessionId {
                state = PaneWarnState(sessionId: agent.sessionId, firstSeenWithoutHook: now, warned: false)
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

    /// Real tick: capture the process-detected agents off-main (the capture runs
    /// sysctl/top and must not block the main thread), then evaluate on main using
    /// the cached, non-blocking hook-session lookup.
    func refresh(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        Task.detached(priority: .utility) {
            let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
            let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: registry,
                fileManager: fileManager
            )
            let agents: [PanelKey: DetectedAgent] = detected.reduce(into: [:]) { acc, pair in
                let snapshot = pair.value.snapshot
                acc[pair.key] = DetectedAgent(kind: snapshot.kind, sessionId: snapshot.sessionId)
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
