#if os(iOS)
/// The mobile app's primary destinations and transient search selection.
enum MobilePrimaryTab: Hashable {
    case workspaces
    case feed
    case notifications
    case search
}
#endif
