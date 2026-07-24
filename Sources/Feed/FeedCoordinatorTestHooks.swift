import CMUXAgentLaunch
import Foundation

#if DEBUG
@MainActor
enum FeedCoordinatorTestHooks {
    static var afterBlockingEventIngested: (@Sendable (WorkstreamEvent, String) -> Void)?
    static var isAppActiveOverride: (@Sendable () -> Bool)?
    static var notificationPostObserver: (@Sendable (WorkstreamEvent, String) -> Void)?
    /// Short-circuits production surfacing so tests do not need a live window route.
    static var attentionSurfaceObserver: (@Sendable (WorkstreamEvent) -> Void)?
    static var pidWatcherArmObserver: (@MainActor (Int) -> Void)?
}
#endif
