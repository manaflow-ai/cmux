import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the non-window domain seams, so a test fake
// that conforms to the full `ControlCommandContext` umbrella only has to
// implement the domain it actually exercises. Each domain's own tests override
// the methods they drive; everything else returns an inert "nothing here"
// result. As domains land, add their defaults here (one block per domain).

extension ControlAppFocusContext {
    func controlSetAppFocusOverride(_ focused: Bool?) {}
    func controlSimulateAppActive() {}
}

extension ControlFeedContext {
    func controlFeedResolvePossibleSurface(workstreamID: String) -> Bool { false }
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] { [] }
}

extension ControlNotificationContext {
    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationCreateResolution { .tabManagerUnavailable }

    func controlNotificationCreateForSurface(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution { .tabManagerUnavailable }

    func controlNotificationCreateForTarget(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution { .tabManagerUnavailable }

    func controlNotificationList() -> [ControlNotificationSnapshot] { [] }
    func controlNotificationDismissAllRead() -> Int { 0 }
    func controlNotificationDismiss(id: UUID) -> ControlNotificationDismissResolution { .notFound }
    func controlNotificationMarkRead(id: UUID) -> ControlNotificationMarkReadResolution { .notFound }
    func controlNotificationMarkRead(
        workspaceID: UUID,
        surfaceID: UUID?,
        hasSurfaceSelector: Bool
    ) -> Int { 0 }
    func controlNotificationMarkReadAll() -> Int { 0 }
    func controlNotificationOpen(id: UUID) -> ControlNotificationOpenResolution { .notificationNotFound }
    func controlNotificationJumpToUnread() -> ControlNotificationSnapshot? { nil }
    func controlNotificationClear() {}

    var notificationStrings: ControlNotificationStrings {
        ControlNotificationStrings(
            dismissSelectorRequired: "",
            idRequired: "",
            notFound: "",
            markReadSelectorRequired: "",
            surfaceIDInvalid: "",
            surfaceIDRequiresWorkspace: "",
            targetNotFound: ""
        )
    }
}
