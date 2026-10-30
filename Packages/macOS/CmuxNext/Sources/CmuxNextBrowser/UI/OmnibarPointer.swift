public import AppKit
import CmuxNextDesign

/// Pointer rules of the browser toolbar and its omnibar (cx-d0d.80). Every
/// view that sets a cursor or a hover in the toolbar follows them; the
/// live check `scripts/cmux-next/omnibar-pointer-live.py` walks them.
///
/// Cursor:
/// - I-beam over the bar's text area (`AddressBarView.textArea`: from the
///   page-info chip to the first trailing badge, the bar's full height),
///   at rest and while editing, as in Safari and Chrome (Lawrence
///   2026-10-13). The same rectangle takes the press that focuses the
///   field, so wherever the I-beam shows, a click focuses.
/// - The pointing hand over an enabled button (`ClickableButton`: Back,
///   Forward, Reload, the toolbar and extension buttons) and the bookmark
///   star, as over every other
///   clickable control in the app's chrome (Leo 2026-10-21: "STOP BUTTON, I
///   HOVER OVER IT, MY CURSOR SHOULD ALSO SEE IT AS CLICKABLE"). A disabled
///   button keeps the arrow.
/// - Arrow everywhere else in the toolbar: the bar beside the chip and the
///   badges, the page-info chip and the badges.
/// - The toolbar row sets the arrow over its whole frame, so a cursor the
///   page set (a link's hand, a text I-beam) never stays when the pointer
///   moves up into the toolbar, and no edge between two rects shows a stale
///   cursor.
///
/// Hover:
/// - One treatment: a theme-token fill (`Palette.hoverFill`, the pill's
///   lift `OmnibarStyle.barFill(.hover, ...)`) that eases in and clears at once
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
        /// The bar around the text inside the text area (above and below
        /// the line, past its end).
        case bar
        /// The bar outside the text area (beside the chip and the badges).
        case barEdge
        /// An enabled button (`ClickableButton`) or the bookmark star.
        case button
        /// A chip, badge or disabled button.
        case control
        /// The toolbar row outside the bar and its buttons.
        case toolbar
    }

    enum Cursor: String, Sendable {
        case arrow
        case iBeam
        case pointingHand

        var cursor: NSCursor {
            switch self {
            case .arrow: .arrow
            case .iBeam: .iBeam
            case .pointingHand: .pointingHand
            }
        }
    }

    /// The cursor for `region`, the same at rest and while editing.
    static func cursor(_ region: Region) -> Cursor {
        switch region {
        case .text, .bar: .iBeam
        case .button: .pointingHand
        case .barEdge, .control, .toolbar: .arrow
        }
    }

    /// The clickable control `view` is or sits in, below `row`: an enabled button
    /// (`ClickableButton`) or the bookmark star. The row's own pointer moves give it the pointing
    /// hand, as its cursor rect does in the key window.
    @MainActor
    static func clickable(at view: NSView, below row: NSView) -> NSView? {
        sequence(first: view, next: \.superview).prefix(while: { $0 !== row }).first { isClickable($0) }
    }

    @MainActor
    static func isClickable(_ view: NSView) -> Bool {
        if let button = view as? ClickableButton { return button.isEnabled }
        return view is BookmarkStarButton
    }
}

extension OmnibarPointer {
    /// The cursor at a window point over `row`: the pointing hand over an
    /// enabled button, the I-beam inside an omnibar's text area (the
    /// rectangle of its cursor rects), the arrow everywhere else in the row.
    @MainActor
    static func cursor(atWindowPoint point: NSPoint, in row: NSView) -> Cursor {
        guard let parent = row.superview, let hit = row.hitTest(parent.convert(point, from: nil)) else { return cursor(.toolbar) }
        if clickable(at: hit, below: row) != nil { return cursor(.button) }
        let bar = sequence(first: hit, next: \.superview).prefix(while: { $0 !== row }).lazy.compactMap { $0 as? AddressBarView }.first
        guard let bar else { return cursor(.toolbar) }
        return bar.textArea.contains(bar.convert(point, from: nil)) ? cursor(.bar) : cursor(.barEdge)
    }
}
