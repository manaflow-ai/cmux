/// Parameters sent when the phone answers a mirrored browser dialog.
public struct MobileBrowserDialogRespondParameters: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Dialog UUID string being answered.
    public let dialogID: String
    /// Selected action identifier.
    public let buttonID: String
    /// Optional entered text; this value can contain a password and must never be logged.
    public let text: String?

    /// Creates a mirrored browser dialog response.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string being answered.
    ///   - buttonID: Selected action identifier.
    ///   - text: Optional entered text, which can be sensitive.
    public init(panelID: String, dialogID: String, buttonID: String, text: String?) {
        self.panelID = panelID
        self.dialogID = dialogID
        self.buttonID = buttonID
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case dialogID = "dialog_id"
        case buttonID = "button_id"
        case text
    }
}
