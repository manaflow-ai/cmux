#if DEBUG
import AppKit

/// DEBUG ONLY: the no-Home prototype window's content view: it keeps its playground alive while the window is open.
final class ChiefNoHomePlaygroundContainer: NSView {
    var owner: AnyObject?
}
#endif
