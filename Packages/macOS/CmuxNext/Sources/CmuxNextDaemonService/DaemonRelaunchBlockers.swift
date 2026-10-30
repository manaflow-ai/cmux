import CoreGraphics
import CmuxNextBridge
public import CmuxUpdater

/// Computes the safe-to-relaunch snapshot for an app update beside ``DaemonService`` so the
/// large CmuxNextApp target does not grow for updater work.
public extension DaemonService {
    /// Reads the daemon's confirmed tab mirror and the acpmux/status overlays.
    /// A relaunch waits for active agent turns and foreground work, while a short hardware-input
    /// quiet window (`quietInput`, nil for ``UpdateRelaunchBlockers/quietInputPeriod``) protects a
    /// focused typing session.
    @MainActor
    func currentRelaunchBlockers(quietInput: Duration? = nil) -> UpdateRelaunchBlockers {
        let quietInput = quietInput ?? UpdateRelaunchBlockers.quietInputPeriod
        guard store.isLoaded,
              case .connected = store.connectionState,
              connection != nil else {
            return .daemonUnavailable
        }
        let tabs = store.workspaces.flatMap { workspace in
            workspace.screens.flatMap { screen in
                screen.panes.flatMap(\.tabs)
            }
        }
        var busyAgents = Set<String>()
        var runningCommands = Set<String>()
        for tab in tabs {
            for report in StatusMapping.shared.reports(tab) {
                switch report.source {
                case .agent where report.state.isWorking:
                    busyAgents.insert(tab.id)
                case .command, .run, .program, .terminalProgress:
                    guard report.state.isLoading || report.state.isWorking else { continue }
                    runningCommands.insert(tab.id)
                default:
                    break
                }
            }
        }
        let inputTimes = [
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .otherMouseDown),
        ]
        let quietSeconds = Double(quietInput.components.seconds) + Double(quietInput.components.attoseconds) / 1e18
        let userInputActive = inputTimes.min() ?? .infinity < quietSeconds
        return UpdateRelaunchBlockers(busyAgentCount: busyAgents.count,
                                      runningCommandCount: runningCommands.count,
                                      userInputActive: userInputActive)
    }
}
