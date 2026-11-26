public import Foundation
public import CmuxNextDesignTokens

/// What a cmux dialog asks (R96: every dialog is a cmux dialog, no system
/// alerts). A spec is plain data: the title, one short sentence per line,
/// optional fields, and the buttons with their roles. `CmuxDialogCenter`
/// shows it in a scope and reports one `CmuxDialogAnswer`.
public nonisolated struct CmuxDialogSpec: Equatable, Sendable {
    /// Non-chat callers opt into the shared material; held chat dialogs retain their current look.
    public var usesTransientMaterial: Bool
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
    /// Whether the card leads with an icon (the spec's, else the app's): false for a card whose title says what it
    /// is (Add Machine), so no column sits empty beside its fields (Leo: "a symbol making space for ABSOLUTLEY NOTHING").
    public var leadsWithIcon: Bool
    /// What the card would otherwise say in a line under its title (what it does, a caveat): an info circle beside
    /// the title shows it on hover, so the card reads as one title and its fields (Leo: "THERE ARE HOVERS AND
    /// QUESTION MARK CIRCLES AND INFO CIRCLES"). Nil: no circle.
    public var info: String?
    /// The accessibility identifier of the dialog view (tests, automation).
    public var identifier: String?
    /// Where the buttons and check boxes go.
    public var layout: Layout
    /// Why the last answer did not go through, drawn in the danger ink above the buttons (the request ended,
    /// the network); nil draws none.
    public var error: String?

    /// How a dialog places its buttons and check boxes.
    public enum Layout: Equatable, Sendable {
        /// Fields above the buttons; the buttons on one line, else stacked the card's width (every dialog).
        case standard
        /// One safe answer among destructive ones (Quit cmux?), as a native alert draws it: Cancel and the
        /// default on one line, the destructive choices as quiet red text buttons on their own line under them,
        /// and the check boxes last, where NSAlert puts its suppression button. No key glyphs: Return and
        /// Escape still answer (Leo, 2026-11-03: "aren't these all kinda awkward looking").
        case safeDefault
        /// A request with several ways to say yes (a device asking to see or control this Mac): every button
        /// the card's width, one under another, so none reads wider or more urgent than its place says. The
        /// default goes first, the other answers next in the spec's order, and the cancel answer last, as quiet
        /// text in the danger ink (Deny): the safe answer, never a filled red block (Lawrence 2026-11-17).
        case stacked

        /// ``safeDefault`` when one of `buttons` is destructive, else ``standard``: the end choices of a
        /// dialog then sit as quiet red text under Cancel and the default (Quit cmux?, Leo 2026-11-03).
        public init(alertFor buttons: [CmuxDialogButton]) {
            self = buttons.contains { $0.role == .destructive } ? .safeDefault : .standard
        }
    }

    public init(usesTransientMaterial: Bool = false, title: String, lines: [String] = [], origin: String? = nil, fields: [CmuxDialogField] = [],
                buttons: [CmuxDialogButton], icon: Data? = nil, leadsWithIcon: Bool = true, info: String? = nil,
                identifier: String? = nil, layout: Layout = .standard, error: String? = nil) {
        self.usesTransientMaterial = usesTransientMaterial
        self.title = title
        self.lines = lines
        self.origin = origin
        self.fields = fields
        self.buttons = buttons
        self.icon = icon
        self.leadsWithIcon = leadsWithIcon
        self.info = info
        self.identifier = identifier
        self.layout = layout
        self.error = error
    }

    /// The button Return presses: the first `.default`, else none. A person-only button is never pressed by a key.
    public var defaultButton: CmuxDialogButton? { buttons.first { $0.role == .default && !$0.personOnly && $0.isEnabled } }
    /// The button Escape presses: the first `.cancel`, else the only button (never a person-only one).
    public var cancelButton: CmuxDialogButton? {
        (buttons.first { $0.role == .cancel } ?? (buttons.count == 1 ? buttons[0] : nil)).flatMap { $0.personOnly || !$0.isEnabled ? nil : $0 }
    }
}
