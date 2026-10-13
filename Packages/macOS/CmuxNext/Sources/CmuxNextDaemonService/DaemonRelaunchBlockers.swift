import CoreGraphics
import CmuxNextBridge
import CmuxUpdater

/// Computes the safe-to-relaunch snapshot for an app update.
///
/// This belongs beside ``DaemonService`` so the large CmuxNextApp target does not grow for
/// updater work. The app supplies this value to ``UpdaterService`` at its wiring boundary.
public enum DaemonRelaunchBlockers {
    /// Reads the daemon's confirmed tab mirror and the acpmux/status overlays.
    /// A relaunch waits for active agent turns and foreground work, while a short hardware-input
    /// quiet window protects a focused typing session.
    @MainActor
    public static func current(for daemon: DaemonService) -> UpdateRelaunchBlockers {
        guard daemon.store.isLoaded,
              case .connected = daemon.store.connectionState,
              daemon.connection != nil else {
            return .daemonUnavailable
        }
        let tabs = daemon.store.workspaces.flatMap { workspace in
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
                case .command, .run, .program, .terminalProgress
                    where report.state.isLoading || report.state.isWorking:
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
        let userInputActive = inputTimes.min() ?? .infinity < 60
        return UpdateRelaunchBlockers(busyAgentCount: busyAgents.count,
                                      runningCommandCount: runningCommands.count,
                                      userInputActive: userInputActive)
    }
}
