import CmuxAgentJournal
import Foundation

/// Drives ``AgentStateScanner`` on a timer.
///
/// Samples only panes whose current state is `running`. That is the one claim
/// the hooks can leave permanently wrong — an interrupted or cleared turn emits
/// no Stop, so the pane is told the agent started and never told it stopped —
/// and it bounds the work to a handful of panes rather than every pane on a
/// timer, which matters when a window holds forty of them.
@MainActor
final class AgentStateScannerRunner {
    static let shared = AgentStateScannerRunner()

    private var timer: Timer?
    private var samples: [AgentHibernationPanelKey: AgentStateScanner.Sample] = [:]
    /// Panes already retired, so a screen that stays still does not re-emit an
    /// event on every tick.
    private var retired: Set<AgentHibernationPanelKey> = []

    private init() {}

    /// Starts or restarts the timer for the configured interval, or stops it
    /// when scanning is disabled.
    func start() {
        timer?.invalidate()
        timer = nil
        let interval = AgentStateScanSettings.intervalSeconds()
        guard interval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { AgentStateScannerRunner.shared.tick() }
        }
        // The scan is diagnostic, not interactive: it must not extend a runloop
        // that is busy drawing or handling keys.
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        samples.removeAll()
        retired.removeAll()
    }

    private func tick(now: TimeInterval = Date().timeIntervalSince1970) {
        guard AgentStateScanSettings.intervalSeconds() > 0 else {
            stop()
            return
        }
        let stillness = AgentStateScanSettings.stillnessSeconds()
        var seen: Set<AgentHibernationPanelKey> = []

        for workspace in AppDelegate.shared?.tabManager?.tabs ?? [] {
            for (panelId, panel) in workspace.panels {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                let states = workspace.agentLifecycleStatesByPanelId[panelId] ?? [:]
                // Only a pane claiming to work can be wrong in the way this
                // scanner fixes, and only its own key may be retired.
                let runningKeys = states
                    .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) && $0.value == .running }
                    .map(\.key)
                guard !runningKeys.isEmpty else { continue }

                let key = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
                seen.insert(key)
                guard let screen = TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel
                ) else {
                    // Unreadable pane: leave it exactly as the hooks left it
                    // rather than guessing from an absence.
                    continue
                }

                let result = AgentStateScanner.observe(
                    screen: screen,
                    previous: samples[key],
                    now: now,
                    stillnessSeconds: stillness
                )
                samples[key] = result.sample
                guard result.verdict == .stale, !retired.contains(key) else {
                    if result.verdict == .working { retired.remove(key) }
                    continue
                }
                retired.insert(key)
                for agentKey in runningKeys.sorted() {
                    emitStale(
                        workspace: workspace,
                        panelId: panelId,
                        agentKey: agentKey,
                        now: now
                    )
                }
            }
        }

        // Forget panes that stopped claiming to run, so a later turn starts
        // from a fresh sample instead of an ancient one.
        samples = samples.filter { seen.contains($0.key) }
        retired = retired.intersection(seen)
    }

    private func emitStale(
        workspace: Workspace,
        panelId: UUID,
        agentKey: String,
        now: TimeInterval
    ) {
        let draft = AgentStateScanner.staleRunningEvent(
            agentKey: agentKey,
            sessionId: nil,
            workspaceId: workspace.id.uuidString,
            surfaceId: panelId.uuidString,
            occurredAtMs: Int64(now * 1000),
            eventId: UUID().uuidString
        )
        guard let data = try? JSONEncoder().encode(draft),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = AgentJournalLifecycleCenter.shared.handleAppendCommand(json)
#if DEBUG
        cmuxDebugLog(
            "agentScan.staleRunning surface=\(panelId.uuidString.prefix(8)) key=\(agentKey)"
        )
#endif
    }
}

/// Settings for the screen scanner.
enum AgentStateScanSettings {
    static let intervalKey = "agentStateScanIntervalSeconds"
    static let stillnessKey = "agentStateScanStillnessSeconds"
    /// On by default: without it, an interrupted turn leaves a pane claiming to
    /// work until the 30-minute stale sweep retires it to *no* state at all.
    static let defaultIntervalSeconds = 5.0
    /// Two ticks of headroom by default. A working agent redraws its elapsed
    /// counter about once a second, so a screen still for this long is not one
    /// whose agent is thinking.
    static let defaultStillnessSeconds = 12.0

    /// Scan interval in seconds; `0` disables scanning. Clamped to a floor so a
    /// mistyped value cannot spin the runloop reading terminals.
    static func intervalSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: intervalKey) != nil else { return defaultIntervalSeconds }
        let value = defaults.double(forKey: intervalKey)
        guard value > 0 else { return 0 }
        return min(max(value, 1), 600)
    }

    /// How long a screen must be unchanged before its turn counts as over.
    static func stillnessSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: stillnessKey) != nil else { return defaultStillnessSeconds }
        let value = defaults.double(forKey: stillnessKey)
        guard value > 0 else { return defaultStillnessSeconds }
        return min(max(value, 2), 3600)
    }
}
