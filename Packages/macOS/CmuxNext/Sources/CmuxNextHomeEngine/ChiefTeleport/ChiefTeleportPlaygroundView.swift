#if DEBUG
import AppKit

/// The Chief Teleport Playground window's content: it keeps its playground alive while the window
/// is open (the playground lets go when the window closes).
final class ChiefTeleportPlaygroundView: NSView {
    var owner: ChiefTeleportPlayground?
}
#endif
