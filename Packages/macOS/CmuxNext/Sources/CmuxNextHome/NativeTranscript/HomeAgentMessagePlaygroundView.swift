#if DEBUG
import AppKit

/// The Agent Messages Playground window's content: it keeps its playground alive while the window is
/// open (the playground lets go when the window closes), and ⌘[ and ⌘] step through the variants.
final class HomeAgentMessagePlaygroundView: NSView {
    var owner: HomeAgentMessagePlayground?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let owner, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "[": owner.step(-1)
        case "]": owner.step(1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
#endif
