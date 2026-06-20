/// The live-responder seam the focus-restore controller drives each attempt
/// through.
///
/// Focus restoration reads and mutates AppKit/WebKit state that cannot live in
/// this package: the live `NSWindow` key state, the `TabManager` focus routing,
/// the focused `Panel`'s responder, and the per-panel focus intent. The
/// ``CommandPaletteFocusRestoreController`` owns only the *lifecycle* (the
/// pending target and its bounded timeout); it delegates every live read/write
/// to a host-provided guard so the package never imports the workspace god
/// object.
///
/// The host conforms a thin adapter in the app target. `Target` is the host's
/// own focus-target value (today the app's `CommandPaletteRestoreFocusTarget`,
/// which stores an app-only `PanelFocusIntent`), so no app type crosses the
/// module boundary.
///
/// ## Isolation
///
/// The guard is `@MainActor`: every member drives SwiftUI/AppKit focus on the
/// main actor, exactly where the previous inline body ran.
@MainActor
public protocol CommandPaletteFocusGuard: AnyObject {
    /// The host's focus-target value passed back into ``attemptRestore(to:)``.
    associatedtype Target

    /// Whether the palette is still presented.
    ///
    /// While `true`, the controller treats a restore attempt as a no-op and
    /// keeps the pending target, matching the legacy
    /// `guard !isCommandPalettePresented else { return }` guard.
    var isPaletteStillPresented: Bool { get }

    /// Drives one focus-restore attempt for `target` and reports the outcome.
    ///
    /// The host performs the live work the previous inline body did: validate
    /// the target workspace still exists, bring the observed window to key,
    /// route `TabManager` focus to the target surface, and ask the focused
    /// panel to restore the captured intent. The returned
    /// ``CommandPaletteFocusRestoreOutcome`` tells the controller whether to
    /// clear or retain the pending target.
    func attemptRestore(to target: Target) -> CommandPaletteFocusRestoreOutcome
}
