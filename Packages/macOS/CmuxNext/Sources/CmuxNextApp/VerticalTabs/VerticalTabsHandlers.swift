import CmuxNextActions
import CmuxNextSettings

/// The App's side of the vertical tabs actions (`VerticalTabsActions` in CmuxNextSettings): the pane a row
/// acts on, the managed-setting check and the cmux.json write.
extension AppActionContext: VerticalTabsHost {
    func verticalTabsPane(_ invocation: ActionInvocation) -> VerticalTabsPane? { paneController(invocation).map(Self.verticalTabsPane) }
    var focusedVerticalTabsPane: VerticalTabsPane? { services.windows.active?.focusedPane.map(Self.verticalTabsPane) }
    func verticalTabsSettingRefusal(_ path: [String]) -> String? { services.settings?.managedKey(forPath: path).map { RefusalStrings.settingManaged($0.key) } }
    func writeVerticalTabsSetting(_ label: String, _ path: [String], _ value: JSONValue?) { writeSetting(label, path, value, reloadOnFailure: true) }

    /// The pane's workspace (whose choice its tab bar follows), and whether it can show a tab bar at all (not an app's or the Home Chief pane).
    private static func verticalTabsPane(_ controller: PaneController) -> VerticalTabsPane {
        VerticalTabsPane(workspaceID: controller.workspace?.workspace.id ?? controller.daemon.store.workspace(containing: controller.pane.handle)?.id,
                         takesVerticalTabs: !controller.isAppPane && !controller.isPinnedDockPane)
    }
}
