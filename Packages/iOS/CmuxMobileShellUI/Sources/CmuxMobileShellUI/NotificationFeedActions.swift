import CmuxMobileRPC

/// User actions exposed by the value-driven notification feed.
struct NotificationFeedActions {
    let refresh: @MainActor @Sendable () async -> Void
    let open: @MainActor (MobileNotificationFeedItem) -> Void
    let toggleRead: @MainActor (MobileNotificationFeedItem) -> Void
    let remove: @MainActor (MobileNotificationFeedItem) -> Void
    let dismissIntro: @MainActor () -> Void
    let enablePush: @MainActor () -> Void
}
