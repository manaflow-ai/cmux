/// The old spelling of four ``DaemonCapability`` wire names, kept only for the sidebar's six reads.
///
/// Interim. The capability catalog is ``DaemonCapability``; this type declares no capability of its
/// own: each member forwards a case's `rawValue`, so the lists, the export and the daemon checks
/// already cover every name here. It is what is left of the old `DaemonCapabilities` catalog,
/// because the sidebar files that read these names (`NotificationCenterService+Sidebar.swift`,
/// `SidebarBridge+Intents.swift`, `SidebarSections/SidebarDocWiring.swift`,
/// `SidebarSections/SidebarLayoutRemote.swift`,
/// `Tests/CmuxNextAppTests/SidebarCmdNumberTwiceTests.swift`) belong to the sidebar owner, who has
/// not yet agreed to the rename. The sidebar owner's follow-up moves those reads to
/// `DaemonCapability.<name>.rawValue` and deletes this file; add no member and no new read.
// lint:allow namespace-type: interim static forwards to DaemonCapability for the held sidebar reads; deleted with the sidebar rename.
@available(*, deprecated, message: "Read DaemonCapability.<name>.rawValue; this interim forwarding type goes with the sidebar rename.")
public struct DaemonCapabilities: Sendable {
    /// No instances: each member is a static forward.
    private init() {}

    /// ``DaemonCapability/sidebarDoc``'s wire name.
    public static let sidebarDoc = DaemonCapability.sidebarDoc.rawValue
    /// ``DaemonCapability/sidebarLayout``'s wire name.
    public static let sidebarLayout = DaemonCapability.sidebarLayout.rawValue
    /// ``DaemonCapability/workspacePin``'s wire name.
    public static let workspacePin = DaemonCapability.workspacePin.rawValue
    /// ``DaemonCapability/notificationAck``'s wire name.
    public static let notificationAck = DaemonCapability.notificationAck.rawValue
}
