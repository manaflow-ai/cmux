import CMUXMobileCore
import Foundation

/// The last-published route set for the unauthenticated `mobile.host.status`
/// probe. The listener republishes routes as it binds, the network path
/// changes, or it stops; a tokenless (or failed-token) status request answers
/// from this cache without touching the main actor, so an arbitrary peer that
/// can reach the port gets a reachability answer without the host doing any
/// per-request work.
///
/// Stays app-side (rather than in ``CMUXMobileCore``) because ``result(includeIdentity:)``
/// renders each route through `CmxAttachRoute.mobileHostJSONObject` (an app
/// extension) and folds it into `MobileHostPublicStatus.jsonObject` /
/// `MobileHostService.identityStatusPayload`, the latter app-owned.
///
/// A real instance type replacing the former caseless-enum namespace; the app
/// holds one process-wide default at its composition point
/// (`MobileHostService.sharedPublicStatusCache`) and threads it to the status
/// and listener paths. Access is guarded by a small `NSLock` rather than an
/// actor because the hot reader (``result(includeIdentity:)``) runs inside the
/// `nonisolated` `networkStatusResult` path and answers synchronously without
/// awaiting, and the guarded state is a single route array: the sanctioned
/// lock-for-tiny-values-read-by-synchronous-code shape. `@unchecked Sendable`
/// is justified because the `NSLock` serializes every read and write of the
/// cached routes.
final class MobileHostPublicStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [CmxAttachRoute] = []

    /// Creates a status cache with an empty route set.
    init() {}

    /// Replaces the cached route set and notifies observers so the Mobile
    /// settings diagnostics reflect the new advertised routes.
    func update(routes nextRoutes: [CmxAttachRoute]) {
        lock.lock()
        routes = nextRoutes
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    /// The cached `mobile.host.status` reply, identity-free by default or with
    /// the Mac's identity when `includeIdentity` is true.
    func result(includeIdentity: Bool = false) -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = routes
        lock.unlock()
        let routesPayload = cachedRoutes.map(\.mobileHostJSONObject)
        return .ok(
            includeIdentity
                ? MobileHostService.identityStatusPayload(routesPayload: routesPayload)
                : MobileHostPublicStatus(routesPayload: routesPayload).jsonObject
        )
    }
}
