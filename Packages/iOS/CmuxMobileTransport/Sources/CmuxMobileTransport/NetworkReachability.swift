import Foundation
public import Observation

/// TRANSITIONAL (iOS refactor): observable forwarding shim over ``ReachabilityService``.
///
/// The real, de-singletonized monitor is ``ReachabilityService`` (an `actor`
/// behind the ``ReachabilityProviding`` seam). This type only exists so the two
/// remaining deep call sites that still read a global keep compiling without a
/// full rewire this step:
///
/// - `CMUXMobileShellStore.observeNetworkPathGeneration()` drives reconnect via
///   `withObservationTracking` on ``pathChangeGeneration``.
/// - `CmuxMobileAuth.AuthManager.requireOnline()` reads ``isOnline``.
///
/// Both call sites belong to singletons slated for the wave 2/3 decomposition
/// (the god store and `AuthManager`); they will take an injected
/// `any ReachabilityProviding` then, and this shim will be deleted. Do not add
/// new callers. The shim subscribes to one process-wide ``ReachabilityService``
/// and republishes its state through `@Observable`, so the underlying monitor is
/// no longer a singleton even while this convenience accessor remains.
@MainActor
@Observable
public final class NetworkReachability {
    /// Process-wide reachability shim. TRANSITIONAL (iOS refactor): forwards onto
    /// a single shared ``ReachabilityService``.
    public static let shared = NetworkReachability(service: ReachabilityService())

    /// Whether the system currently has a satisfied network path.
    public private(set) var isOnline: Bool = true

    /// Convenience inverse of ``isOnline``.
    public var isOffline: Bool { !isOnline }

    /// Monotonic counter that increments on each meaningful path change.
    ///
    /// Observe it via `withObservationTracking` to drive reconnect/resync when
    /// the underlying network moves out from under a live connection. It mirrors
    /// the change events of the backing ``ReachabilityService``.
    public private(set) var pathChangeGeneration: Int = 0

    private let service: any ReachabilityProviding

    /// Creates a shim that republishes the given reachability provider.
    /// - Parameter service: The provider whose state and change events to mirror.
    public init(service: any ReachabilityProviding) {
        self.service = service
        // Weakly observe the provider's change stream; the loop ends when the
        // shim is released because each iteration bails out on a nil `self`.
        Task { [weak self] in
            await self?.refreshOnline()
            for await _ in service.pathChanges() {
                guard let self else { return }
                self.pathChangeGeneration &+= 1
                await self.refreshOnline()
            }
        }
    }

    private func refreshOnline() async {
        let online = await service.isOnline
        isOnline = online
    }
}
