public import CmuxNextActions
public import CmuxNextDesign

/// The pane a vertical tabs row acts on, as the App sees it.
public struct VerticalTabsPane: Equatable, Sendable {
    /// The workspace whose choice the pane's tab bar follows (``WorkspaceVerticalTabs``).
    public var workspaceID: String?
    /// The pane can show a tab bar at all: not an app's pane, not the Home Chief pane.
    public var takesVerticalTabs: Bool

    public init(workspaceID: String?, takesVerticalTabs: Bool) {
        self.workspaceID = workspaceID
        self.takesVerticalTabs = takesVerticalTabs
    }
}

/// What the vertical tabs actions (``VerticalTabsActions``) read from the App: the design settings, the
/// pane a row acts on, the managed-setting check and the cmux.json write.
@MainActor
public protocol VerticalTabsHost {
    /// The design settings the rows read and change (`tabs.verticalTabs`, `tabs.verticalTabsExpandOnHover`).
    var design: DesignSettings { get }
    /// The pane `invocation` targets (the right-clicked tab bar's), if any.
    func verticalTabsPane(_ invocation: ActionInvocation) -> VerticalTabsPane?
    /// The active window's focused pane, which the palette's rows name.
    var focusedVerticalTabsPane: VerticalTabsPane? { get }
    /// Why the setting at `path` cannot change here (a managed value holds it), else nil.
    func verticalTabsSettingRefusal(_ path: [String]) -> String?
    /// Writes `value` at `path` (nil removes it) through the validated settings path; a failed write
    /// reloads the settings. `label` names the setting in the log.
    func writeVerticalTabsSetting(_ label: String, _ path: [String], _ value: JSONValue?)
}
