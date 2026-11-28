/// What opened the "Introducing cmux Cloud" welcome card.
public enum CloudWelcomeTrigger: String, Sendable, CaseIterable {
    /// The one-time release announcement on the first main window.
    case launchAnnouncement = "launch_announcement"
    /// New Cloud Workspace (shortcut, menu or palette) while Cloud is off or signed out.
    case newCloudWorkspace = "new_cloud_workspace"
    /// New Cloud Machine (shortcut, menu or palette) while Cloud is off or signed out.
    case newCloudMachine = "new_cloud_machine"
    /// The sidebar footer Cloud button while Cloud is off or signed out.
    case sidebarCloudButton = "sidebar_cloud_button"
    /// The Debug menu preview. Debug builds only.
    case debugMenu = "debug_menu"
}
