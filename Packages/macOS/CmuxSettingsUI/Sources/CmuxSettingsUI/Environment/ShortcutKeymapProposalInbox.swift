import CmuxSettings
import Observation

/// Hands a base keymap chosen outside Settings (the Command Palette) to the
/// Keyboard Shortcuts section, which previews it and applies it only when the
/// user confirms.
@MainActor
@Observable
public final class ShortcutKeymapProposalInbox {
    /// The preset waiting for a preview, or `nil` when nothing is pending.
    public var preset: ShortcutKeymapPreset?

    /// Whether something outside Settings asked for the base keymap chooser.
    ///
    /// The Keyboard Shortcuts section clears this when it opens the chooser.
    /// The first-run chooser does not go through here: it is a sheet on the
    /// main window so a fresh install is not dropped into Settings.
    public var isChooserRequested = false

    /// Creates an empty inbox.
    public init() {}
}
