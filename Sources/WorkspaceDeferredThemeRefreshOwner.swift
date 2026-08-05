/// Holds hidden-workspace refresh data without publishing a SwiftUI state
/// mutation for every global theme notification.
@MainActor
final class WorkspaceDeferredThemeRefreshOwner {
    private var pending: WorkspaceDeferredThemeRefresh?

    func record(_ refresh: WorkspaceDeferredThemeRefresh) {
        pending = WorkspaceDeferredThemeRefresh(
            reason: refresh.reason,
            backgroundOverride: refresh.backgroundOverride,
            backgroundEventId: refresh.backgroundEventId,
            backgroundSource: refresh.backgroundSource,
            notificationPayloadHex: refresh.notificationPayloadHex,
            forceInitialApply: refresh.forceInitialApply || pending?.forceInitialApply == true
        )
    }

    func takePending() -> WorkspaceDeferredThemeRefresh? {
        defer { pending = nil }
        return pending
    }

    func clear() {
        pending = nil
    }
}
