public import Foundation

/// What a cmux dialog asks (R96: every dialog is a cmux dialog, no system
/// alerts). A spec is plain data: the title, one short sentence per line,
/// optional fields, and the buttons with their roles. `CmuxDialogCenter`
/// shows it in a scope and reports one `CmuxDialogAnswer`.
public nonisolated struct CmuxDialogSpec: Equatable, Sendable {
    public var title: String
    /// One short sentence per line.
    public var lines: [String]
    /// The web origin that asked (JavaScript dialogs, HTTP auth), shown
    /// above the message so a page cannot pose as cmux.
    public var origin: String?
    public var fields: [CmuxDialogField]
    /// Left to right as drawn. Return presses the `.default` button, Escape
    /// the `.cancel` button; a button's `key` is pressed with Command.
    public var buttons: [CmuxDialogButton]
    /// PNG or TIFF data for an icon (extension prompts); nil draws none.
    public var icon: Data?
    /// The accessibility identifier of the dialog view (tests, automation).
    public var identifier: String?

    public init(title: String, lines: [String] = [], origin: String? = nil, fields: [CmuxDialogField] = [],
                buttons: [CmuxDialogButton], icon: Data? = nil, identifier: String? = nil) {
        self.title = title
        self.lines = lines
        self.origin = origin
        self.fields = fields
        self.buttons = buttons
        self.icon = icon
        self.identifier = identifier
    }

    /// The button Return presses: the first `.default`, else none.
    public var defaultButton: CmuxDialogButton? { buttons.first { $0.role == .default } }
    /// The button Escape presses: the first `.cancel`, else the only button.
    public var cancelButton: CmuxDialogButton? {
        buttons.first { $0.role == .cancel } ?? (buttons.count == 1 ? buttons[0] : nil)
    }
}
