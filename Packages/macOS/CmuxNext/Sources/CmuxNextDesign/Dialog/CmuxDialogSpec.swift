public import Foundation
public import CmuxNextDesignTokens

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
    /// Where the buttons and check boxes go.
    public var layout: Layout

    /// How a dialog places its buttons and check boxes.
    public enum Layout: Equatable, Sendable {
        /// Fields above the buttons; the buttons on one line, else stacked the card's width (every dialog).
        case standard
        /// One safe answer among destructive ones (Quit cmux?), as a native alert draws it: Cancel and the
        /// default on one line, the destructive choices as quiet red text buttons on their own line under them,
        /// and the check boxes last, where NSAlert puts its suppression button. No key glyphs: Return and
        /// Escape still answer (Leo, 2026-11-03: "aren't these all kinda awkward looking").
        case safeDefault

        /// ``safeDefault`` when one of `buttons` is destructive, else ``standard``: the end choices of a
        /// dialog then sit as quiet red text under Cancel and the default (Quit cmux?, Leo 2026-11-03).
        public init(alertFor buttons: [CmuxDialogButton]) {
            self = buttons.contains { $0.role == .destructive } ? .safeDefault : .standard
        }
    }

    public init(title: String, lines: [String] = [], origin: String? = nil, fields: [CmuxDialogField] = [],
                buttons: [CmuxDialogButton], icon: Data? = nil, identifier: String? = nil, layout: Layout = .standard) {
        self.title = title
        self.lines = lines
        self.origin = origin
        self.fields = fields
        self.buttons = buttons
        self.icon = icon
        self.identifier = identifier
        self.layout = layout
    }

    /// The button Return presses: the first `.default`, else none.
    public var defaultButton: CmuxDialogButton? { buttons.first { $0.role == .default } }
    /// The button Escape presses: the first `.cancel`, else the only button.
    public var cancelButton: CmuxDialogButton? {
        buttons.first { $0.role == .cancel } ?? (buttons.count == 1 ? buttons[0] : nil)
    }
}
