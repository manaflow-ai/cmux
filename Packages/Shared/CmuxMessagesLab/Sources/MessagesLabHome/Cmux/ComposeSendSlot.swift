import CoreGraphics
import Foundation

/// cmux: where the compose field's send button sits and whether it shows (`ComposeSendButton`).
///
/// The slot is the field's trailing 30 pt, where Messages draws the voice waveform. The text never
/// enters it (`ComposeView`'s text frame always leaves it, so the first character typed does not
/// rewrap the field). The button is centred 15.5 pt above the field's bottom, the centre of a
/// one-line field: a taller field grows upward, so the button stays on the last line's baseline
/// row and does not move while the field grows, shrinks after a send or scrolls past its max height.
/// The centre is as far from the right edge as from the bottom, so the 24 pt disc has the same
/// 3.5 pt gap to both edges (Lawrence 2026-10-23: "make right and bottom padding the same").
struct ComposeSendSlot: Equatable {
    /// The field's trailing width the text leaves free (the waveform's, and the button's).
    static let trailingReserve: CGFloat = 30
    /// The button's centre from the field's right edge (the same as from its bottom).
    static let centreFromRight: CGFloat = centreFromBottom
    /// The button's centre above the field's bottom (half a one-line field).
    static let centreFromBottom: CGFloat = 15.5
    /// The button's hit target (its view's size; the disc inside is 24 pt).
    static let target: CGFloat = 28

    /// The button's frame (the field's coordinates, y down).
    let frame: CGRect
    /// Text or an attachment is in the field: the button replaces the waveform.
    let shown: Bool
    /// There is something to send (the projection's rule: text other than spaces, or an attachment).
    let enabled: Bool

    init(field: CGRect, text: String, attachments: Int) {
        let size = Self.target
        let centre = CGPoint(x: field.maxX - Self.centreFromRight, y: field.maxY - Self.centreFromBottom)
        frame = CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size)
        shown = !text.isEmpty || attachments > 0
        // The attachment marks (U+FFFC) are not text to send.
        let plain = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        enabled = attachments > 0 || !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
