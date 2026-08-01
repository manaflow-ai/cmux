/// Notification that a mirrored browser dialog has been resolved.
public struct MobileBrowserDialogResolvedEvent: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Dialog UUID string that is no longer pending.
    public let dialogID: String

    /// Creates a dialog-resolution notification.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string that is no longer pending.
    public init(panelID: String, dialogID: String) {
        self.panelID = panelID
        self.dialogID = dialogID
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case dialogID = "dialog_id"
    }
}
