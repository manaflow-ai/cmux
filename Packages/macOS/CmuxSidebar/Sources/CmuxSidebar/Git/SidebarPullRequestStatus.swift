/// Lifecycle status of a sidebar pull-request row.
///
/// Raw values are a control-socket wire format; frozen.
public enum SidebarPullRequestStatus: String, Sendable, Equatable {
    case open
    case merged
    case closed
}
