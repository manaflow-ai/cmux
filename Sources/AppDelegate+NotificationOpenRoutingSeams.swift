import AppKit
import CmuxNotifications
import Foundation

/// Reference wrapper that lets a value-typed ``AppDelegate/RegisteredMainWindow``
/// ride through the `CmuxNotifications` open-routing seams as an opaque
/// `AnyObject` context token. `RegisteredMainWindow` is a struct, so it cannot be
/// an `AnyObject` directly; this box is minted once in
/// `openRoutingContextToken(forTabId:)` and handed straight back by the
/// coordinator, so every in-context primitive reads the same resolved context,
/// exactly as the legacy `openNotificationInContext` body did.
@MainActor
final class RegisteredMainWindowToken {
    let context: AppDelegate.RegisteredMainWindow

    init(_ context: AppDelegate.RegisteredMainWindow) {
        self.context = context
    }
}

/// App-side adapter that lets the `CmuxNotifications` open-routing seams reach
/// `AppDelegate` WITHOUT forming a retain cycle, mirroring
/// ``NotificationNavSeamAdapter`` exactly. ``NotificationOpenRoutingCoordinator``
/// strong-refs this adapter; the adapter holds a `weak var owner: AppDelegate?`
/// and conforms to every seam by forwarding to internal `AppDelegate` helpers, so
/// the graph has no strong path back to `AppDelegate` (which would pin the
/// app-host test instance).
///
/// When the owner is alive (production and the package tests) every method is
/// byte-identical to the old in-`AppDelegate` body; when it has deallocated each
/// degrades to the same empty/no-op/false/nil the seams already use for missing
/// late-bound state. Legal per CONVENTIONS §6: the window mechanics and the
/// `#if DEBUG` UI-test recorders stay app-side while the routing skeleton lives
/// in the package.
@MainActor
final class NotificationOpenRoutingSeamAdapter:
    NotificationOpenRoutingHosting,
    NotificationOpenRoutingTracing
{
    weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
    }

    // MARK: NotificationOpenRoutingHosting

    func contextToken(forTabId tabId: UUID) -> AnyObject? {
        owner?.openRoutingContextToken(forTabId: tabId)
    }

    func contextWindowToken(forContextToken contextToken: AnyObject) -> AnyObject? {
        owner?.openRoutingContextWindowToken(forContextToken: contextToken)
    }

    func selectSidebarTabs(forContextToken contextToken: AnyObject) {
        owner?.openRoutingSelectSidebarTabs(forContextToken: contextToken)
    }

    func focusTabFromNotification(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    ) -> Bool {
        owner?.openRoutingFocusTab(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId
        ) ?? false
    }

    var hasActiveTabManager: Bool {
        owner?.openRoutingHasActiveTabManager ?? false
    }

    func activeTabManagerContains(tabId: UUID) -> Bool {
        owner?.openRoutingActiveTabManagerContains(tabId: tabId) ?? false
    }

    func keyOrMainTerminalWindowToken() -> AnyObject? {
        owner?.openRoutingKeyOrMainTerminalWindowToken()
    }

    func selectActiveSidebarTabs() {
        owner?.openRoutingSelectActiveSidebarTabs()
    }

    func focusTabInActiveTabManager(tabId: UUID, surfaceId: UUID?) -> Bool {
        owner?.openRoutingFocusTabInActiveTabManager(tabId: tabId, surfaceId: surfaceId) ?? false
    }

    func bringWindowToFront(_ windowToken: AnyObject) {
        owner?.openRoutingBringWindowToFront(windowToken)
    }

    func markNotificationRead(notificationId: UUID?) {
        owner?.openRoutingMarkNotificationRead(notificationId: notificationId)
    }

    // MARK: NotificationOpenRoutingTracing

    func traceOpenCalled(tabId: UUID, surfaceId: UUID?) {
        owner?.openRoutingTraceOpenCalled(tabId: tabId, surfaceId: surfaceId)
    }

    func recordOpenFailureMissingContext(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) {
        owner?.openRoutingRecordOpenFailureMissingContext(
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        )
    }

    func traceContextMissingUsedFallback() {
        owner?.openRoutingTraceContextMissingUsedFallback()
    }

    func traceOpenResult(_ ok: Bool) {
        owner?.openRoutingTraceOpenResult(ok)
    }

    func traceContextFoundNoFallback() {
        owner?.openRoutingTraceContextFoundNoFallback()
    }

    func recordOpenFailureMissingWindow(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    ) {
        owner?.openRoutingRecordOpenFailureMissingWindow(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        )
    }

    func traceInContextFocusFailed(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    ) {
        owner?.openRoutingTraceInContextFocusFailed(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        )
    }

    func recordJumpUnreadFocusFromModelInContext(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    ) {
        owner?.openRoutingRecordJumpUnreadFocusFromModelInContext(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId
        )
    }

    func traceInContextOpened(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    ) {
        owner?.openRoutingTraceInContextOpened(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId
        )
    }

    func traceFallbackFailed(stage: String) {
        owner?.openRoutingTraceFallbackFailed(stage: stage)
    }

    func recordJumpUnreadFocusFromModelActive(tabId: UUID, surfaceId: UUID?) {
        owner?.openRoutingRecordJumpUnreadFocusFromModelActive(tabId: tabId, surfaceId: surfaceId)
    }

    func traceFallbackFocusFailed() {
        owner?.openRoutingTraceFallbackFocusFailed()
    }

    func traceOpenedInFallback() {
        owner?.openRoutingTraceOpenedInFallback()
    }
}
