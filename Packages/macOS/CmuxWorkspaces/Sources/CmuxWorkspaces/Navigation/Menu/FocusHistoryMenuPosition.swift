/// Whether a menu item sits before or after the current history position.
public enum FocusHistoryMenuPosition: Equatable, Sendable {
    /// The item is older than the current position.
    case older
    /// The item is newer than the current position.
    case newer
}
