import CmuxMobileModel
import CmuxMobileWorkspaces
import Foundation

extension ShellLaunchOptions {
    /// `-cmux-mobile-no-restore` starts from a fresh session: besides not reopening the last
    /// workspace, the Workspaces list and Home open on their defaults (All Macs, no grouping).
    ///
    /// The Mac filter and Group by are remembered across launches in UserDefaults, and every UI
    /// test shares one simulator: a suite that picks a Mac (the all-UI-states capture's
    /// "filtered-offline-mac" scene leaves MacBook Pro chosen) otherwise scoped every later
    /// suite's list to that Mac, so `workspace.row.ws-cmux` and the offline fold never showed.
    /// Call once at launch, before any view reads either value.
    public static func clearListViewStateIfNotRestoring(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) {
        guard arguments.contains("-cmux-mobile-no-restore") else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(MacFilter.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: WorkspaceListGrouping.defaultsKey)
    }
}
