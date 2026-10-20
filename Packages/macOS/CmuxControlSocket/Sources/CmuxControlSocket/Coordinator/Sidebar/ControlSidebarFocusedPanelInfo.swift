public import Foundation

/// The focused panel and its known directory for the `sidebar_state` listing
/// (present only when both are known, matching the legacy `focused_cwd` /
/// `focused_panel` pairing).
public struct ControlSidebarFocusedPanelInfo: Sendable, Equatable {
    /// The focused panel id.
    public let panelID: UUID
    /// The focused panel's reported directory.
    public let directory: String

    /// Creates the info pair.
    ///
    /// - Parameters:
    ///   - panelID: The focused panel id.
    ///   - directory: The focused panel's reported directory.
    public init(panelID: UUID, directory: String) {
        self.panelID = panelID
        self.directory = directory
    }
}
