import CoreGraphics

/// Where the iOS composer sits relative to the keyboard.
///
/// The composer hangs below a base line 4 pt above the keyboard layout guide.
/// Its offset below that line (the "drop") is measured on Messages (iOS 26.5
/// and 27.0, iPhone 17 Pro, pixel rows of the field's edge): at rest the
/// field's bottom sits 28 pt above the screen bottom (6 pt into the home
/// indicator's safe area); with the keyboard up it sits 16 pt above the
/// keyboard's top edge.
///
/// The keyboard's real top edge decides the drop. The composer rides
/// `dockedDrop` above it, and never sits lower than its resting place. An
/// animated show or hide interpolates between those two end states on the
/// keyboard's own curve. An interactive dismissal moves the keyboard with the
/// finger, frame by frame, and the composer stays the same distance above it
/// all the way to the screen edge. That includes the last stretch below the
/// safe area, where the layout guide stops following the keyboard.
public enum ConversationKeyboardPinGeometry {
    /// Drop below the base line with no keyboard.
    public static let restDrop: CGFloat = 14
    /// Drop below the base line with the keyboard up (negative: above it).
    public static let dockedDrop: CGFloat = -8

    /// The composer's drop below its base line.
    /// - Parameters:
    ///   - keyboardTop: the keyboard's top edge, or the screen's bottom edge
    ///     when no keyboard covers the composer.
    ///   - guideTop: the keyboard layout guide's top edge (the base line sits
    ///     4 pt above it).
    ///   - restingGuideTop: the guide's top edge with no keyboard (the bottom
    ///     safe-area edge).
    public static func drop(keyboardTop: CGFloat, guideTop: CGFloat, restingGuideTop: CGFloat) -> CGFloat {
        min(keyboardTop + dockedDrop, restingGuideTop + restDrop) - guideTop
    }

    /// The keyboard's top edge as the composer should follow it, or nil
    /// when the composer should hold still.
    ///
    /// UIKit's interactive dismissal puts the keyboard's top edge, and the
    /// layout guide's, at the finger once the finger is below the docked
    /// keyboard. The guide stops at the bottom safe-area edge; below it the
    /// finger alone tells where the keyboard is. When the finger lets go,
    /// UIKit puts the guide back at rest before it animates the keyboard away
    /// (and posts the keyboard notification inside that animation), so a
    /// guide at rest under a finger still above the safe area means "hold
    /// until the keyboard's own animation moves you".
    /// - Parameters:
    ///   - guideTop: the keyboard layout guide's top edge.
    ///   - restingGuideTop: the guide's top edge with no keyboard.
    ///   - screenBottom: the bottom edge of the view.
    ///   - dragLocation: the finger's location while it drags the transcript
    ///     over a shown keyboard, else nil.
    public static func keyboardTop(guideTop: CGFloat, restingGuideTop: CGFloat, screenBottom: CGFloat, dragLocation: CGFloat?) -> CGFloat? {
        if guideTop < restingGuideTop - 0.5 { return guideTop }
        guard let dragLocation else { return screenBottom }
        guard dragLocation >= restingGuideTop - 0.5 else { return nil }
        return min(screenBottom, dragLocation)
    }
}
