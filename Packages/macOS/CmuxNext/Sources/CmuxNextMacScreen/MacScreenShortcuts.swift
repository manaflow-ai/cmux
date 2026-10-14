public import AppKit
public import CmuxNextActions

extension MacScreenPages {
    /// Keeps cmux's own shortcuts (new tab, close tab, switching panes) in
    /// cmux on a Mac Screen: Command or Control chords only, since a plain
    /// key (a single-letter binding) always types on the other Mac. The
    /// clipboard and undo chords go to the other Mac, where the selection is.
    public func useShortcuts(of registry: ActionRegistry) {
        isLocalShortcut = { [weak registry] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !flags.isDisjoint(with: [.command, .control]), let registry, registry.resolveShortcut(for: event) != nil else { return false }
            let editing: Set<String> = ["c", "v", "x", "a", "z"]
            if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased(), editing.contains(key) {
                return false
            }
            return true
        }
    }
}
