/// Pure z-order decision for a terminal scroll view's transient overlays.
///
/// This is the terminal-domain home of the sibling-ordering branch logic that
/// lived in `GhosttySurfaceScrollView.updateImageTransferIndicatorZOrder` and
/// `updateKeyboardCopyModeBadgeZOrder`. Each witness keeps its AppKit identity
/// checks (`superview === self`), its `isHidden` early-return guards, and the
/// `addSubview(_:positioned:.above,relativeTo:)` side effect; it resolves those
/// live AppKit conditions to plain `Bool`s and asks this type only which sibling
/// the new view should be positioned above, so the decision stays a
/// deterministic, testable value computation that references no AppKit.
public struct TerminalOverlayZOrderPolicy: Sendable {
    /// One of the scroll view's overlay siblings a view can be positioned above.
    public enum Sibling: Sendable, Equatable {
        /// The caller-supplied overlay sibling (a search or selection overlay).
        case overlay
        /// The keyboard-copy-mode badge container.
        case keyboardCopyModeBadge
    }

    /// Where a transient overlay should be inserted in the sibling z-order.
    public enum Placement: Sendable, Equatable {
        /// Position the view immediately above the given sibling
        /// (`relativeTo:` that sibling's view).
        case above(Sibling)
        /// Position the view above all siblings (`relativeTo: nil`).
        case aboveAll
    }

    /// Creates a stateless terminal overlay z-order policy.
    public init() {}

    /// Where the image-transfer indicator should sit relative to its siblings.
    ///
    /// Sits above the caller's overlay when that overlay is a live sibling;
    /// otherwise sits above the keyboard-copy-mode badge when the badge is a
    /// live, visible sibling; otherwise sits above everything. The witness has
    /// already applied the indicator's own `isHidden` guard before calling this.
    public func imageTransferIndicatorPlacement(
        overlayIsSelfSibling: Bool,
        badgeIsSelfSibling: Bool,
        badgeHidden: Bool
    ) -> Placement {
        if overlayIsSelfSibling {
            return .above(.overlay)
        }
        if badgeIsSelfSibling, !badgeHidden {
            return .above(.keyboardCopyModeBadge)
        }
        return .aboveAll
    }

    /// Where the keyboard-copy-mode badge should sit relative to its siblings.
    ///
    /// Sits above the caller's overlay when that overlay is a live sibling;
    /// otherwise sits above everything. The witness has already applied the
    /// badge's own `isHidden` guard before calling this.
    public func keyboardCopyModeBadgePlacement(
        overlayIsSelfSibling: Bool
    ) -> Placement {
        overlayIsSelfSibling ? .above(.overlay) : .aboveAll
    }
}
