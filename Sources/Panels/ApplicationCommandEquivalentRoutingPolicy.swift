import AppKit

/// Chooses native document shortcuts that the captured application receives
/// before cmux evaluates its own menu equivalents.
struct ApplicationCommandEquivalentRoutingPolicy {
    /// Matches produced characters so non-US keyboard layouts preserve
    /// their native AppKit command semantics.
    func shouldRouteThroughContentFirst(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = browserOmnibarNormalizedModifierFlags(
            event.modifierFlags
        )
        guard let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return false
        }
        switch flags {
        case [.command]:
            return [
                "a", "b", "c", "f", "g", "i", "l", "o", "p",
                "r", "s", "u", "v", "x", "z",
            ].contains(key)
        case [.command, .shift]:
            return ["f", "g", "z"].contains(key)
        default:
            return false
        }
    }
}
