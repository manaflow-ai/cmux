import AppKit
import CmuxNextDesign

/// Pointer rules of the browser toolbar and its omnibar (cx-d0d.80). Every
/// view that sets a cursor or a hover in the toolbar follows them; the
/// live check `scripts/cmux-next/omnibar-pointer-live.py` walks them.
///
/// Cursor:
/// - I-beam only over the text while the omnibar edits it. At rest a click
///   selects the whole address (it does not place a caret), so the resting
///   field shows the arrow, as a button does.
/// - Arrow everywhere else in the toolbar: the bar around the text, the
///   page-info chip, the badges, the star and every button. A toolbar
///   control is not a link, so it never shows the pointing hand.
/// - The toolbar row sets the arrow over its whole frame, so a cursor the
///   page set (a link's hand, a text I-beam) never stays when the pointer
///   moves up into the toolbar, and no edge between two rects shows a stale
///   cursor.
///
/// Hover:
/// - One treatment: a theme-token fill (`Palette.hoverFill`, the pill's
///   lift `OmnibarStyle.barHoverFill`) that eases in and clears at once
///   (`ChromeHover.fade`), so a sweep across the buttons leaves no trail.
/// - Hover is where the pointer is now (`PointerHover`), recomputed when the
///   view hides, shows or changes window: a tab switch, a parked pane or a
///   collapsed button under a still pointer leaves no hover behind.
/// - A disabled control and the bar while it edits show no hover.
///
/// Focus (the omnibar state machine, `OmnibarReducer`, owns the rules):
/// the first click anywhere in the bar focuses it and selects the whole
/// address; a second click places the caret; Cmd-L focuses and selects;
/// Escape reverts typed text, and Escape with nothing typed returns the
/// keyboard to the page. Text fields draw no focus ring of their own: the
/// pill's editing ring is the one focus look (cx-ncc.57).
enum OmnibarPointer {
    /// Where the pointer is, as far as the cursor rules care.
    enum Region: String, Sendable {
        /// The omnibar's text.
        case text
        /// The bar around the text (padding, the gap before the badges).
        case bar
        /// A chip, badge, star or button.
        case control
        /// The toolbar row outside the bar and its buttons.
        case toolbar
    }

    enum Cursor: String, Sendable {
        case arrow
        case iBeam

        var cursor: NSCursor { self == .iBeam ? .iBeam : .arrow }
    }

    /// The cursor for `region`; `editing` is whether the omnibar edits its text.
    static func cursor(_ region: Region, editing: Bool) -> Cursor {
        region == .text && editing ? .iBeam : .arrow
    }
}

/// A toolbar row that shows the arrow over its whole frame
/// (`OmnibarPointer`): subviews with their own cursor rects (the editing
/// omnibar text) take precedence inside it.
final class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: OmnibarPointer.cursor(.toolbar, editing: false).cursor)
    }
}
