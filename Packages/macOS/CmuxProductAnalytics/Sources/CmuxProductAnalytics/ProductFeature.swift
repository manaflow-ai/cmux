/// A key product surface, counted at most once per day by ``ProductAnalytics/featureUsed(_:)``.
public enum ProductFeature: String, Sendable, CaseIterable {
    case commandPalette = "command_palette"
    case filesExplorer = "files_explorer"
    case find
    case vault
    case feed
    case dock
    case cloudSidebar = "cloud_sidebar"
    case customSidebar = "custom_sidebar"
    /// The Cloud sidebar's Devices section.
    case devices
    case cmuxSSH = "cmux_ssh"
    case browserPane = "browser_pane"
    case split
}
