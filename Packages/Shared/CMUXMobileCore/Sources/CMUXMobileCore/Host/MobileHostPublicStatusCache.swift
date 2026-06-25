public import Foundation

/// Caches the host's currently-advertised attach routes and projects them into
/// the `mobile.host.status` reply bodies.
///
/// The host learns its reachable routes asynchronously (the listener binds a
/// port, the network path changes, Tailscale hosts come and go) and a network
/// caller can ask for `mobile.host.status` at any time, including from the
/// unauthenticated probe path that never touches the main actor. So the routes
/// live behind an `NSLock` here: `update(routes:)` is called from the host's
/// lifecycle transitions, and `publicPayload()`/`identityPayload(...)` are read
/// from the request-serving path. A single lock owns every access to the one
/// stored field, so `@unchecked Sendable` is justified by that lock.
///
/// This is a constructor-injected instance, not a static namespace:
/// `MobileHostService` owns one instance and forwards its ~20 update/result call
/// sites into it, replacing the previous lock-guarded static-state
/// `MobileHostPublicStatusCache` namespace. The status-change notification is
/// injected as `onChange` because the `mobileHostStatusDidChange`
/// `Notification.Name` is declared app-side; the app passes a closure that posts
/// it so this package stays free of the app-defined name.
///
/// The `.ok(...)` wrapping into the app's `MobileHostRPCResult` and the resolved
/// identity strings (`MobileHostBuildIdentity`/`MobileHostIdentity`) stay
/// app-side: this owner only stores the routes and produces the pure
/// `[String: Any]` payloads through ``MobileHostStatusPayloadProjector``.
public final class MobileHostPublicStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [CmxAttachRoute] = []
    private let onChange: @Sendable () -> Void

    /// - Parameter onChange: Called after `update(routes:)` mutates the cached
    ///   routes. Production passes a closure that posts
    ///   `mobileHostStatusDidChange` so the Mobile settings diagnostics observe
    ///   the live routes; tests can pass a no-op.
    public init(onChange: @escaping @Sendable () -> Void = {}) {
        self.onChange = onChange
    }

    /// Replaces the cached routes and notifies observers.
    public func update(routes nextRoutes: [CmxAttachRoute]) {
        lock.lock()
        routes = nextRoutes
        lock.unlock()
        onChange()
    }

    /// The identity-free `mobile.host.status` payload (routes, fidelity,
    /// capabilities) for an unauthenticated reachability probe. The caller wraps
    /// it into `MobileHostRPCResult.ok(_:)` app-side.
    public func publicPayload() -> [String: Any] {
        projector().publicPayload
    }

    /// The status payload plus the Mac's identity, for a caller that has proven
    /// same-account Stack ownership. The identity strings are resolved app-side
    /// (`MobileHostIdentity` is `UserDefaults`-backed, `MobileHostBuildIdentity`
    /// reads `Bundle.main`) and passed in; the caller wraps the result into
    /// `MobileHostRPCResult.ok(_:)` app-side. A `nil` `displayName`,
    /// `appVersion`, or `appBuild` omits that key, matching the legacy
    /// projection exactly.
    public func identityPayload(
        deviceID: String,
        displayName: String?,
        appVersion: String?,
        appBuild: String?
    ) -> [String: Any] {
        projector().identityPayload(
            deviceID: deviceID,
            displayName: displayName,
            appVersion: appVersion,
            appBuild: appBuild
        )
    }

    private func projector() -> MobileHostStatusPayloadProjector {
        lock.lock()
        let cachedRoutes = routes
        lock.unlock()
        return MobileHostStatusPayloadProjector(
            routesPayload: cachedRoutes.map(\.mobileHostJSONObject)
        )
    }
}
