/// The omnibar's focus and pointer state at the moment a focus decision is made,
/// paired with the pure predicate that decision reduces to.
///
/// These are deterministic reductions over the omnibar's responder and pointer
/// state, with no side effects. Each decision is modeled as a small `Sendable`
/// value carrying its inputs as stored properties and exposing the result as a
/// computed property, so the AppKit field editor can construct the value from
/// live state and read the boolean, and a test can exercise the predicate
/// without an `NSTextField`.

/// Whether the omnibar should re-acquire first responder after it ends editing.
///
/// The omnibar reclaims focus only when it still wants focus and the responder
/// taking over is not another text field (handing focus to a different field is
/// an explicit move the omnibar must not fight).
public struct BrowserOmnibarEndEditingFocusDecision: Sendable, Equatable {
    /// `true` when the omnibar still wants to be focused.
    public let desiredOmnibarFocus: Bool

    /// `true` when the responder gaining focus is a different text field.
    public let nextResponderIsOtherTextField: Bool

    /// Creates the decision from the omnibar's end-of-editing focus state.
    /// - Parameters:
    ///   - desiredOmnibarFocus: `true` when the omnibar still wants focus.
    ///   - nextResponderIsOtherTextField: `true` when another text field is
    ///     taking over.
    public init(desiredOmnibarFocus: Bool, nextResponderIsOtherTextField: Bool) {
        self.desiredOmnibarFocus = desiredOmnibarFocus
        self.nextResponderIsOtherTextField = nextResponderIsOtherTextField
    }

    /// `true` only when the omnibar wants focus and no other text field is
    /// taking over.
    public var shouldReacquireFocus: Bool {
        desiredOmnibarFocus && !nextResponderIsOtherTextField
    }
}

/// Whether a completed single click that just moved first responder into the
/// omnibar should select the field's entire contents (Chrome/Safari/Arc
/// parity), instead of leaving the caret the field editor placed at the click
/// point.
///
/// The first click on an unfocused omnibar showing a URL selects everything so
/// the user can immediately type a replacement. A subsequent click (the field is
/// already first responder, so `gainedFocusOnThisClick` is `false`) keeps the
/// caret placement from https://github.com/manaflow-ai/cmux/issues/5268. A drag
/// or a Shift-click expresses an explicit range, so select-all defers to it; a
/// double-click never reaches this path (the field routes multi-clicks straight
/// to the field editor for word/line selection, and its second click lands after
/// this click's `mouseUp`, so word selection wins).
public struct BrowserOmnibarFocusGainingClick: Sendable, Equatable {
    /// `true` when the field had no field editor at `mouseDown`, i.e. this click
    /// is the one that moved focus into the omnibar.
    public let gainedFocusOnThisClick: Bool

    /// `true` when Shift was held, extending an explicit selection.
    public let isShiftClick: Bool

    /// `true` when the pointer moved far enough to build a drag selection.
    public let didDrag: Bool

    /// Creates the click from the gesture's focus and pointer state.
    /// - Parameters:
    ///   - gainedFocusOnThisClick: `true` when this click moved focus into the
    ///     omnibar.
    ///   - isShiftClick: `true` when Shift was held.
    ///   - didDrag: `true` when the pointer dragged far enough to select a range.
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
