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

    /// Creates an empty inbox.
    public init() {}
}
