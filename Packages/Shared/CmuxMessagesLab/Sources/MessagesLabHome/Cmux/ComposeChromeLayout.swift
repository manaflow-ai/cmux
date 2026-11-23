import CoreGraphics

/// cmux: which glass buttons a compose bar of a given width shows, and where its field goes.
///
/// Messages' bar is fixed chrome around the field: the "+" button 10.5 pt in, the field 9.5 pt right
/// of it, the emoji button the same on the right, and the text 12 pt inside the field with the send
/// button's slot after it. A Home pane narrower than Messages' smallest window (a split's third
/// column, about 150 pt) left the text no width, and the draft broke after every character. Below
/// ``minTextWidth`` the emoji button goes first (the system's emoji shortcut still opens the
/// picker), then the "+" button (files still come in by drag and paste), and the field takes their
/// room. At Messages' window widths nothing changes: both buttons show where Messages draws them.
struct ComposeChromeLayout: Equatable {
    /// The text width the bar keeps before it gives a button's room to the field: about a dozen
    /// characters of the 17 pt body font, so a short draft stays on its line.
    static let minTextWidth: CGFloat = 96
    /// From the bar's edge to a button.
    static let margin: CGFloat = 10.5
    /// A glass button's width.
    static let button: CGFloat = 31
    /// From a button to the field.
    static let gap: CGFloat = 9.5
    /// The text's insets inside the field, both sides together (`ComposeView`'s text frame).
    static let textInsets: CGFloat = 24
    /// From the bar's edge to the field when a button stands between them (Messages' 51 pt).
    static let buttonSide: CGFloat = margin + button + gap

    /// The "+" button shows.
    let showsPlus: Bool
    /// The emoji button shows.
    let showsEmoji: Bool
    /// The field's left edge in the bar.
    let fieldX: CGFloat
    /// The field's width.
    let fieldWidth: CGFloat
    /// The emoji button's left edge in the bar (where it stands when it shows).
    let emojiX: CGFloat

    /// The layout of a bar `width` pt wide. The send button's slot (`ComposeSendSlot.trailingReserve`)
    /// decides, not the wider slot while dictating, so starting the voice input never drops a button.
    init(width: CGFloat) {
        let reserve = Self.textInsets + ComposeSendSlot.trailingReserve
        let emoji = width - 2 * Self.buttonSide - reserve >= Self.minTextWidth
        let plus = emoji || width - Self.buttonSide - Self.margin - reserve >= Self.minTextWidth
        showsEmoji = emoji
        showsPlus = plus
        fieldX = plus ? Self.buttonSide : Self.margin
        fieldWidth = max(0, width - fieldX - (emoji ? Self.buttonSide : Self.margin))
        emojiX = width - Self.margin - Self.button
    }
}
