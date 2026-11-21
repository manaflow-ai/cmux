/// Which interactions close an overlay shown in the command palette layer.
///
/// The overlay controller asks this before hiding, so the choice for each kind of
/// overlay lives here rather than in its dismissal handlers.
public struct CommandPaletteDismissalPolicy: Sendable, Equatable {
    /// Whether the overlay stays open, with its state, while its window is not key.
    public let staysOpenWhileWindowIsNotKey: Bool

    /// Closes on a click outside, on the menu bar opening, and when its window stops being key.
    public static let closesOnAnyInteraction = Self(staysOpenWhileWindowIsNotKey: false)

    /// Stays open while the user is in another app or window; a click outside it or
    /// the menu bar still closes it.
    public static let staysOpenAcrossKeyChanges = Self(staysOpenWhileWindowIsNotKey: true)

    /// Whether `dismissal` closes the overlay.
    public func dismisses(_ dismissal: CommandPaletteInteractionDismissal) -> Bool {
        switch dismissal {
        case .windowResignedKey: !staysOpenWhileWindowIsNotKey
        case .pointer, .mainMenuBeganTracking: true
        }
    }
}
