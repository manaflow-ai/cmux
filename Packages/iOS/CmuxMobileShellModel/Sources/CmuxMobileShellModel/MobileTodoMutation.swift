public import CMUXMobileCore

/// One mutation supported by the native mobile todo surface.
public enum MobileTodoMutation: Equatable, Sendable {
    /// Append a user-authored pending item.
    case add(text: String)
    /// Set an item's state.
    case setState(itemID: String, state: MobileTodoItemState)
    /// Replace an item's text.
    case edit(itemID: String, text: String)
    /// Move an item toward a full-list index within its completion partition.
    case move(itemID: String, toIndex: Int)
    /// Remove an item.
    case remove(itemID: String)
    /// Open or focus the workspace todo pane on the Mac.
    case openOnMac
    /// Set a status lane, or clear the override when the value is `nil`.
    case setStatus(MobileTodoStatus?)
    /// Advance the effective status to the next lane.
    case cycleStatus
}
