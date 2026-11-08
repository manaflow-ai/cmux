/// A native Mac browser dialog mirrored as data to a phone.
public struct MobileBrowserDialogEvent: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Dialog UUID string used for exactly-once resolution.
    public let dialogID: String
    /// Native browser interaction represented by this dialog.
    public let kind: MobileBrowserDialogKind
    /// Mac-provided title displayed verbatim, when present.
    public let title: String?
    /// Mac-provided message displayed verbatim, when present.
    public let message: String?
    /// Origin host associated with the request, when present.
    public let host: String?
    /// Actions offered by the dialog.
    public let buttons: [MobileBrowserDialogButton]
    /// Text-entry metadata, when the dialog accepts text.
    public let textField: MobileBrowserDialogTextField?
    /// Whether the phone can only cancel while the interaction remains Mac-only.
    public let informational: Bool

    /// Creates a native browser dialog event.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string.
    ///   - kind: Native browser interaction represented by the dialog.
    ///   - title: Mac-provided title displayed verbatim.
    ///   - message: Mac-provided message displayed verbatim.
    ///   - host: Origin host associated with the request.
    ///   - buttons: Actions offered by the dialog.
    ///   - textField: Text-entry metadata, when applicable.
    ///   - informational: Whether the interaction must be completed on the Mac.
    public init(
        panelID: String,
        dialogID: String,
        kind: MobileBrowserDialogKind,
        title: String?,
        message: String?,
        host: String?,
        buttons: [MobileBrowserDialogButton],
        textField: MobileBrowserDialogTextField?,
        informational: Bool
    ) {
        self.panelID = panelID
        self.dialogID = dialogID
        self.kind = kind
        self.title = title
        self.message = message
        self.host = host
        self.buttons = buttons
        self.textField = textField
        self.informational = informational
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case dialogID = "dialog_id"
        case kind
        case title
        case message
        case host
        case buttons
        case textField = "text_field"
        case informational
    }
}
