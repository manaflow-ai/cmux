public import Observation

/// What the saved groups bar asks the App to do.
public enum SavedGroupsBarIntent: Hashable, Sendable {
    /// Click: focus the group if open, else restore it into the active pane.
    case open(TabGroupID)
}

/// Input of a `SavedGroupsBarView`. The App mirrors the daemon's saved
/// group records into `groups`.
@Observable
public final class SavedGroupsBarModel {
    public var groups: [SavedTabGroupItem]
    @ObservationIgnored public var intentHandler: ((SavedGroupsBarIntent) -> Void)?

    public init(groups: [SavedTabGroupItem] = []) {
        self.groups = groups
    }

    public func send(_ intent: SavedGroupsBarIntent) {
        intentHandler?(intent)
    }
}
