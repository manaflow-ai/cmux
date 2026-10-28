import CmuxNextWakeups

extension LaunchServicePosts {
    /// The browser follows that neither the first frame nor a page engine reads:
    /// history's daemon sync and the location trail's scope, each its own afterFirstFrame post. What a
    /// page engine or the first frame reads (the profiles, the engine preference, the link click and
    /// managed browser policy, the page schemes, the bookmarks bar, the omnibar look) stays in the
    /// launch turn, ordered before the first page.
    ///
    /// - Parameters:
    ///   - historyDaemonSync: Keeps each daemon's command recording and closed-history retention in step
    ///     with the settings (`HistoryService.startDaemonSync(settings:)`).
    ///   - locationTrailScope: Follows `navigation.historyScope` (`LocationTrailService.watchScope(settings:)`).
    /// - Returns: The two posts, afterFirstFrame, in that order.
    public static func browserFollows(historyDaemonSync: @escaping @MainActor @Sendable () -> Void,
                                      locationTrailScope: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "History.startDaemonSync", work: historyDaemonSync),
            Post(priority: .afterFirstFrame, name: "LocationTrail.watchScope", work: locationTrailScope),
        ])
    }
}
