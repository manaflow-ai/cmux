/// A completed single click on the browser omnibar, deciding whether it should
/// select the field's entire contents (Chrome/Safari/Arc parity) instead of
/// leaving the caret the field editor placed at the click point.
///
/// The first click on an unfocused omnibar showing a URL selects everything so
/// the user can immediately type a replacement. A subsequent click (the field is
/// already first responder, so `gainedFocusOnThisClick` is `false`) keeps the
/// caret placement from https://github.com/manaflow-ai/cmux/issues/5268. A drag
/// or a Shift-click expresses an explicit range, so select-all defers to it; a
/// double-click never reaches this path (the field routes multi-clicks straight
/// to the field editor for word/line selection, and its second click lands after
/// this click's `mouseUp`, so word selection wins).
///
/// The app target inlined this as a free
/// `browserOmnibarFocusGainingClickShouldSelectAll(...)` function; it is a pure
/// decision over three booleans with no AppKit responder reach, so it moves here
/// as a small value type carrying its inputs and exposing the decision as
/// ``shouldSelectAll`` (a real value type, not a static-method namespace). The
/// body is a byte-faithful lift.
public struct BrowserOmnibarFocusGainingClick: Equatable, Sendable {
    /// `true` when the field had no field editor at `mouseDown`, i.e. this click
    /// is the one that moved focus into the omnibar.
    public let gainedFocusOnThisClick: Bool
    /// `true` when Shift was held, extending an explicit selection.
    public let isShiftClick: Bool
    /// `true` when the pointer moved far enough to build a drag selection.
    public let didDrag: Bool

    /// Creates the focus-gaining click decision inputs.
    public init(gainedFocusOnThisClick: Bool, isShiftClick: Bool, didDrag: Bool) {
        self.gainedFocusOnThisClick = gainedFocusOnThisClick
        self.isShiftClick = isShiftClick
        self.didDrag = didDrag
    }

    /// `true` only for an undragged, unmodified focus-gaining click.
    public var shouldSelectAll: Bool {
        gainedFocusOnThisClick && !isShiftClick && !didDrag
    }
}
