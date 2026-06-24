/// App-resolved icon names for a session agent, handed to the package "Show more"
/// popover so it can render agent glyphs without reaching the app-side
/// `SessionAgent` presentation extension.
///
/// The asset-catalog name and SF Symbol fallback live in the app (the asset names
/// reference the app's catalog), so the popover takes them as already-resolved
/// values through the ``SectionPopoverView/agentIcon`` seam rather than computing
/// them itself.
public struct AgentIconPresentation: Sendable {
    /// The app-resolved asset-catalog icon name for the agent, or `nil`.
    public let assetName: String?
    /// The app-resolved SF Symbol fallback name, or `nil`.
    public let systemImageName: String?

    /// Creates a resolved agent-icon presentation.
    public init(assetName: String?, systemImageName: String?) {
        self.assetName = assetName
        self.systemImageName = systemImageName
    }
}
