#if os(iOS)
/// The searchable primary destination that owns the persistent search tab.
///
/// New primary tabs must explicitly choose whether they introduce a search
/// scope; destinations without one hide the search control.
enum MobilePrimarySearchScope: Equatable {
    case feed
    case workspaces
    case notifications
}
#endif
