import AppKit

/// A button cell that draws a disabled button's title in the inks of the button's own `attributedTitle`.
///
/// AppKit repaints a disabled button's title in the system's disabled ink, which on a themed fill read as
/// no title at all (``CmuxDialogButtonView``'s fill; a ``ThemedBezelButton``'s selection bezel, #C2C3C3 on
/// #F6F7F7 in NativeControlContrastAuditTests). A button using this cell picks its disabled ink itself.
class OwnInkButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard !isEnabled, title.length == attributedTitle.length else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        // The title as AppKit laid it out (centered), in the button's own inks.
        let own = NSMutableAttributedString(attributedString: title)
        attributedTitle.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: own.length)) { ink, range, _ in
            if let ink { own.addAttribute(.foregroundColor, value: ink, range: range) }
        }
        return super.drawTitle(own, withFrame: frame, in: controlView)
    }
}
