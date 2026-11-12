import AppKit

/// The one-letter answers on a sidebar row that can answer its chat's pending tool permission (the
/// Needs You tray, a Priority row), as the agent pane's permission card takes them: y allows once,
/// n denies. Only the bare letter: a held Command, Control or Option leaves the key to its shortcut.
/// Rows read it only while they hold the keyboard focus, so a text field never gives one up. A held
/// key's repeats answer nothing: one press answers one prompt, never the next one to arrive.
enum SidebarAnswerKey: Equatable {
    case allow
    case deny

    /// The answer `characters` (the key's characters ignoring Shift) names with `modifiers` held; nil for any other key
    /// and for a held key's repeat.
    init?(characters: String?, modifiers: NSEvent.ModifierFlags, repeating: Bool = false) {
        guard !repeating, modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch characters?.lowercased() {
        case "y": self = .allow
        case "n": self = .deny
        default: return nil
        }
    }

    init?(_ event: NSEvent) {
        self.init(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags, repeating: event.isARepeat)
    }

    var allows: Bool { self == .allow }
}
