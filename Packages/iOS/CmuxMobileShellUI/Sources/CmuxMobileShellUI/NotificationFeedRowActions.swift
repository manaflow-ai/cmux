/// Row-scoped actions that keep the list subtree independent of observable stores.
struct NotificationFeedRowActions {
    let open: @MainActor () -> Void
    let toggleRead: @MainActor () -> Void
    let remove: @MainActor () -> Void
}
