import CmuxNextActions
import CmuxNextAppCore
import CmuxNextDaemon
import Foundation

/// Restore Previous App Launch (`reopenPreviousSession`): the one path for its palette row, File
/// menu item, Cmd-Shift-O, the sidebar menu, `cmux workspace restore-previous-app-launch` and MCP.
/// Relaunch already brings back every window the previous launch left open (`WindowManager.restore`);
/// this reopens those of them closed since, with the workspaces closed since from them, each
/// through the daemon's closed history (`DaemonClosedHistory.reopen`), so they come back with
/// their tabs and leave the Recently Closed list.
@MainActor
struct PreviousLaunchRestorer {
    let services: AppServices

    /// Reopens what ``PreviousLaunch/plan(closed:registry:install:)`` lists; throws when it lists nothing.
    func restore() throws {
        let windows = services.windows
        guard let launch = windows.previousLaunch else { throw ActionFailure.invalidTarget(HistoryAppStrings.nothingFromPreviousLaunch) }
        let entries = DaemonClosedHistory.entries(DaemonClosedHistory.allKinds, in: services)
        let plan = launch.plan(closed: entries.map(\.item), registry: windows.registry.value,
                               install: try? services.cloud.localDeviceID())
        guard !plan.isEmpty else { throw ActionFailure.invalidTarget(HistoryAppStrings.nothingFromPreviousLaunch) }
        for id in plan.windowIDs { windows.reopenClosedWindow(id: id) }
        for id in plan.closedIDs {
            if let entry = entries.first(where: { $0.item.id == id }) { DaemonClosedHistory.reopen(entry, services: services) }
        }
    }
}
