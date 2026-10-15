import Foundation

/// One row of a composed page context menu.
public enum BrowserContextMenuEntry: Hashable, Sendable {
    /// An engine item; choosing it reports the item's id back to the engine.
    case engine(BrowserContextMenuItem)
    /// A cmux action the host runs itself.
    case host(BrowserContextMenuHostAction)
    /// A separator line.
    case separator
}
