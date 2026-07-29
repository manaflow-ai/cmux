#if os(iOS)
/// The searchable primary destination that owns the persistent search tab.
///
/// New primary tabs must explicitly choose whether they introduce a search
/// scope or preserve the most recent searchable destination.
enum MobilePrimarySearchScope: Equatable {
    case workspaces
    case notifications
}
#endif
