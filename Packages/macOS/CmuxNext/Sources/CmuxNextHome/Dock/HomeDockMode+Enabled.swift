public import CmuxNextHomeModel
import CmuxNextDesign

extension HomeDockMode {
    /// Whether the view may show: Messages always; Channels while `home.channelsEnabled` is on (the
    /// palette's Enable Channels; Lawrence 2026-10-15).
    @MainActor public var isEnabled: Bool { self == .messages || DesignSettings.shared.homeChannelsEnabled }
}
